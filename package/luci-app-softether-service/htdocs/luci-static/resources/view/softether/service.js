'use strict';
'require fs';
'require rpc';
'require ui';
'require view';

/*
 * Controls the SoftEther VPN **server** service. It deliberately avoids
 * fs.exec_direct(): that helper posts to /cgi-bin/cgi-exec, which rpcd denies
 * with 403 for most ACLs, and the caller then hangs forever. Everything here
 * goes through the ubus based fs.exec() plus the `service` ubus object.
 */

var initd = '/etc/init.d/softethervpnserver';
var vpncmd = '/usr/bin/vpncmd';
var svcName = 'softethervpnserver';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

function collectState(res) {
	var svc = (res && res[svcName]) ? res[svcName] : null;
	var out = { running: false, pid: null, boot: false, bootProbeFailed: false };

	if (svc && svc.instances) {
		Object.keys(svc.instances).forEach(function(k) {
			var ins = svc.instances[k];
			if (ins && ins.running) {
				out.running = true;
				if (ins.pid)
					out.pid = ins.pid;
			}
		});
	}

	return out;
}

/*
 * Every branch resolves with a value: a rejected promise here would leave the
 * view stuck on its loading placeholder, which is the failure mode this page
 * replaces.
 */
function loadState() {
	return Promise.all([
		callServiceList(svcName).catch(function(e) { return null; }),
		fs.exec(initd, [ 'enabled' ]).catch(function(e) { return null; })
	]).then(function(r) {
		var st = collectState(r[0]);

		if (r[1] === null) {
			st.bootProbeFailed = true;
		}
		else {
			st.boot = (r[1].code === 0);
		}

		return st;
	});
}

function runAction(args, label) {
	ui.addNotification(null, E('p', '正在执行：' + label), 'info');

	return fs.exec(initd, args).then(function(res) {
		if (res.code !== 0) {
			ui.addNotification(null, E('p', [
				'命令返回状态 ' + res.code,
				res.stderr ? E('br') : null,
				res.stderr ? String(res.stderr).trim() : null
			]), 'error');

			return;
		}

		/*
		 * This LuCI build has no L.refresh(); reloading is what the working
		 * upstream apps here do (luci-app-argon-config uses location.reload()
		 * after every action).
		 */
		location.reload();
	}).catch(function(e) {
		ui.addNotification(null, E('p', '操作失败：' + (e && e.message ? e.message : e)), 'error');
	});
}

function button(label, cls, args) {
	return E('button', {
		class: 'btn %s'.format(cls),
		style: 'margin-right:.4em',
		click: function() { return runAction(args, label); }
	}, label);
}

/*
 * SoftEther holds hub/user changes in memory until it is told to write them
 * out, so give the operator a way to flush without stopping the service.
 */
function runFlush() {
	ui.addNotification(null, E('p', '正在保存配置'), 'info');

	return fs.exec(vpncmd, [ 'localhost:5555', '/server', '/CMD', 'Flush' ]).then(function(res) {
		if (res.code !== 0) {
			ui.addNotification(null, E('p', [
				'保存失败，命令返回状态 ' + res.code,
				res.stderr ? E('br') : null,
				res.stderr ? String(res.stderr).trim() : null
			]), 'error');

			return;
		}

		ui.addNotification(null, E('p', '配置已写入 /etc/softethervpn-server/vpn_server.config'), 'success');
	}).catch(function(e) {
		ui.addNotification(null, E('p', '保存失败：' + (e && e.message ? e.message : e)), 'error');
	});
}

function row(key, value) {
	return E('tr', { class: 'tr' }, [
		E('td', { class: 'td', style: 'width:33%' }, key),
		E('td', { class: 'td' }, value)
	]);
}

return view.extend({
	load: function() {
		return loadState();
	},

	render: function(st) {
		var runningBadge = st.running
			? E('em', { class: 'badge success' }, '运行中')
			: E('em', { class: 'badge warning' }, '已停止');

		var bootBadge;
		if (st.bootProbeFailed)
			bootBadge = E('em', { class: 'badge minor' }, '未知（读取失败）');
		else if (st.boot)
			bootBadge = E('em', { class: 'badge success' }, '已启用');
		else
			bootBadge = E('em', { class: 'badge warning' }, '未启用');

		return E([
			E('h2', 'SoftEther VPN Server'),

			E('table', { class: 'table' }, [
				row('服务名称', 'softethervpnserver'),
				row('当前状态', runningBadge),
				row('进程 PID', st.running && st.pid ? String(st.pid) : '—'),
				row('开机自启', bootBadge)
			]),

			E('div', { class: 'buttons' }, [
				button('启动', 'primary', [ 'start' ]),
				button('停止', 'danger', [ 'stop' ]),
				button('重启', 'warning', [ 'restart' ]),
				E('button', {
					class: 'btn secondary',
					style: 'margin-right:.4em',
					click: function() { return runFlush(); }
				}, '保存配置到磁盘'),
				st.boot
					? button('取消开机自启', 'secondary', [ 'disable' ])
					: button('设为开机自启', 'secondary', [ 'enable' ])
			]),

			E('div', { class: 'alert-message' }, E('p', [
				'配置文件保存在 ', E('code', '/etc/softethervpn-server/vpn_server.config'),
				'（可写 overlay，已加入 sysupgrade 备份清单）。',
				E('br'),
				'但 SoftEther 平时把改动留在内存里，只在收到 ', E('code', 'Flush'),
				' 或正常停止服务时才写盘：新建/修改 HUB、用户、端口后请点 ',
				E('b', '保存配置到磁盘'),
				'（本镜像的 init 脚本已会在 stop 前自动 Flush，正常 reboot 也会落盘；直接断电则未 Flush 的改动会丢）。',
				E('br'),
				'默认监听端口：443、992、1194、5555。',
				E('br'),
				'443 与 uhttpd 的 HTTPS 监听冲突，两者只会有一方拿到该端口（可用 ',
				E('code', 'netstat -ltnp | grep :443'),
				' 确认）。',
				E('br'),
				'首次使用需要先设置服务端管理密码并创建虚拟 HUB：',
				E('code', 'vpncmd localhost:5555 /server'),
				' 内执行 ',
				E('code', 'ServerPasswordSet'),
				'、',
				E('code', 'HubCreate'),
				'、',
				E('code', 'UserCreate'),
				'，最后 ',
				E('code', 'Flush'),
				'。'
			]))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
