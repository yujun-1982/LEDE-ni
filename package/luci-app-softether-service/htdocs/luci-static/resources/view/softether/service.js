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
var flushBin = '/usr/libexec/softethervpn-flush';
var clampBin = '/usr/libexec/softethervpn-set-autosave';
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
 *
 * Both actions go through helper scripts under /usr/libexec instead of calling
 * vpncmd here: once a server management password is set, a bare `Flush` is
 * refused, and the helpers read /etc/softethervpn-server/management.password.
 * The password therefore never travels through the browser.
 */
function runHelper(busyText, okText, bin, args) {
	ui.addNotification(null, E('p', busyText), 'info');

	return fs.exec(bin, args).then(function(res) {
		if (res.code !== 0) {
			ui.addNotification(null, E('p', [
				'操作失败，命令返回状态 ' + res.code,
				E('br'),
				String(res.stderr || '').trim() || '（无输出）',
				E('br'),
				'若服务端已设置管理密码，请在设备上执行：umask 077; printf \'%s\\n\' \'服务端密码\' > /etc/softethervpn-server/management.password'
			]), 'error');

			return;
		}

		ui.addNotification(null, E('p', okText + (String(res.stdout || '').trim() ? ' — ' + String(res.stdout).trim() : '')), 'success');
	}).catch(function(e) {
		ui.addNotification(null, E('p', '操作失败：' + (e && e.message ? e.message : e)), 'error');
	});
}

function runFlush() {
	return runHelper('正在保存配置', '配置已写入 /etc/softethervpn-server/vpn_server.config', flushBin, []);
}

function runClamp() {
	return runHelper('正在调整自动保存间隔', '自动保存间隔已调整', clampBin, [ '300' ]);
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
				E('button', {
					class: 'btn secondary',
					style: 'margin-right:.4em',
					click: function() { return runClamp(); }
				}, '每 5 分钟自动保存'),
				st.boot
					? button('取消开机自启', 'secondary', [ 'disable' ])
					: button('设为开机自启', 'secondary', [ 'enable' ])
			]),

			E('div', { class: 'alert-message' }, E('p', [
				'配置文件保存在 ', E('code', '/etc/softethervpn-server/vpn_server.config'),
				'（可写 overlay，已加入 sysupgrade 备份清单）。',
				E('br'),
				'但 SoftEther 平时把改动留在内存里，只在收到 ', E('code', 'Flush'),
				'、正常停止服务、或',
				E('b', '自动保存间隔'),
				'到期时才写盘。新建/修改 HUB、用户、端口、本地桥接后请点 ',
				E('b', '保存配置到磁盘'),
				'。硬重启（Proxmox 的"重启"、直接断电）不走关机脚本，所以还要保证自动保存间隔是 5 分钟而不是出厂默认的 24 小时 —— 点 ',
				E('b', '每 5 分钟自动保存'),
				'即可。',
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
				'。',
				E('br'),
				E('b', '注意'),
				'：一旦设置了服务端管理密码，上面两个按钮以及 stop 时的自动 Flush 都需要它，请在设备上把密码写进 ',
				E('code', '/etc/softethervpn-server/management.password'),
				'（权限 600，只存在设备上，不要提交到仓库），否则改动只靠 5 分钟自动保存落盘。'
			]))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
