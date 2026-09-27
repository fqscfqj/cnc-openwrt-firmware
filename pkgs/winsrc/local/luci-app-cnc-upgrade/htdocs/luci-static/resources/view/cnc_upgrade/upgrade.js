'use strict';
'require view';
'require fs';
'require ui';

/*
 * CncTion 1338NP-12 固件在线升级页面
 *
 * 页面的职责只有三件事：调用 /usr/sbin/cnc-upgrade、展示 JSON 结果、确认后触发刷写。
 * 所有下载/校验/刷写逻辑都在 shell 脚本里（便于脱离硬件做单元测试）。
 */

var SCRIPT = '/usr/sbin/cnc-upgrade';

function callCmd(cmd) {
	return fs.exec(SCRIPT, [ cmd ]).then(function(res) {
		var out = (res.stdout || '').trim();
		var parsed = null;

		try { parsed = out ? JSON.parse(out) : null; } catch (e) { parsed = null; }

		if (res.code !== 0 || !parsed || parsed.ok !== true) {
			var msg = (res.stderr || '').trim() || out ||
				_('命令执行失败（exit %d）').format(res.code);
			throw new Error(msg);
		}

		return parsed;
	});
}

function fmtSize(n) {
	n = +n || 0;
	var unit = [ 'B', 'KiB', 'MiB', 'GiB' ], i = 0;

	while (n >= 1024 && i < unit.length - 1) { n /= 1024; i++; }

	return '%.1f %s'.format(n, unit[i]);
}

return view.extend({
	load: function() {
		return callCmd('check').then(function(r) {
			return { check: r };
		}, function(e) {
			return { error: String(e.message || e) };
		});
	},

	handleCheck: function() {
		var self = this;

		ui.showModal(_('检查更新'), [
			E('p', { 'class': 'spinning' }, _('正在获取版本信息…'))
		]);

		return callCmd('check').then(function(r) {
			self.state.check = r;
			self.state.error = null;
			self.state.download = null;
			ui.hideModal();
			self.paint();
			ui.addNotification(null, E('p', {}, _('已获取最新版本信息')), 'info');
		}, function(e) {
			self.state.error = String(e.message || e);
			ui.hideModal();
			self.paint();
		});
	},

	handleDownload: function() {
		var self = this;

		ui.showModal(_('下载并校验'), [
			E('p', { 'class': 'spinning' }, _('正在下载固件并校验 sha256，请耐心等待（文件约 250–300 MB）…'))
		]);

		return callCmd('download').then(function(r) {
			self.state.download = r;
			self.state.error = null;
			ui.hideModal();
			self.paint();
			ui.addNotification(null, E('p', {}, _('固件已下载并通过校验')), 'info');
		}, function(e) {
			self.state.error = String(e.message || e);
			ui.hideModal();
			self.paint();
		});
	},

	handleFlash: function() {
		var self = this;

		ui.showModal(_('确认刷写并重启'), [
			E('p', {}, _('将使用已校验的固件刷写，设备会立即重启。配置（/etc/config、插件数据）默认保留。')),
			E('p', { 'class': 'alert-message warning' }, _('刷写过程中请勿断电；请确认串口线已接好（ttyS0 / 115200 8N1），那是唯一的救援通道。')),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'click': ui.hideModal
				}, _('取消')),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': function() {
						ui.hideModal();
						ui.showModal(_('正在刷写'), [
							E('p', { 'class': 'spinning' }, _('正在写入固件，设备即将重启，请不要关闭电源…'))
						]);
						callCmd('flash').catch(function() { /* 设备重启会导致连接中断，属正常 */ });
					}
				}, _('开始刷写'))
			])
		]);
	},

	paint: function() {
		var st = this.state, nodes = [];
		var cur = (st.check && st.check.current) || {};
		var rem = (st.check && st.check.remote) || {};

		if (st.error)
			nodes.push(E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, _('操作失败：')), E('br'), st.error
			]));

		nodes.push(E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('项目')),
				E('th', { 'class': 'th' }, _('当前设备')),
				E('th', { 'class': 'th' }, _('远端最新'))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, _('OpenWrt 版本')),
				E('td', { 'class': 'td left' }, cur.openwrt_version || '—'),
				E('td', { 'class': 'td left' }, rem.openwrt_version || '—')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, _('固件构建号')),
				E('td', { 'class': 'td left' }, cur.firmware_build || '—'),
				E('td', { 'class': 'td left' }, rem.firmware_build || '—')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, _('内核')),
				E('td', { 'class': 'td left' }, '—'),
				E('td', { 'class': 'td left' }, rem.kver || '—')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, _('镜像文件')),
				E('td', { 'class': 'td left' }, '—'),
				E('td', { 'class': 'td left' }, [
					rem.file || '—',
					rem.size ? E('br') : '',
					rem.size ? fmtSize(rem.size) : ''
				])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, _('sha256')),
				E('td', { 'class': 'td left' }, '—'),
				E('td', { 'class': 'td left' }, [
					E('code', {}, rem.sha256 ? rem.sha256.substring(0, 24) + '…' : '—')
				])
			])
		]));

		var status;
		if (!st.check) {
			status = E('p', {}, _('尚未检查更新。'));
		}
		else if (!st.check.available) {
			status = E('p', { 'class': 'alert-message success' }, _('已是最新固件，无需升级。'));
		}
		else {
			var dir = st.check.direction;
			var label = (dir === 'downgrade') ? _('可回退到该版本') :
				(dir === 'same' ? _('同版本不同构建') : _('发现新固件'));
			status = E('p', { 'class': 'alert-message ' + (dir === 'downgrade' ? 'warning' : 'info') },
				_('%s：%s / %s').format(label, rem.openwrt_version || '?', rem.firmware_build || '?'));
		}
		nodes.push(status);

		if (st.download)
			nodes.push(E('p', { 'class': 'alert-message success' },
				_('已下载并校验：%s（%s）').format(st.download.path, fmtSize(st.download.size))));

		var buttons = [
			E('button', { 'class': 'btn', 'click': ui.createHandlerFn(this, 'handleCheck') }, _('检查更新')),
			' ',
			E('button', {
				'class': 'btn',
				'click': ui.createHandlerFn(this, 'handleDownload'),
				'disabled': (st.check && st.check.available) ? null : 'disabled'
			}, _('下载并校验')),
			' ',
			E('button', {
				'class': 'btn cbi-button-action important',
				'click': ui.createHandlerFn(this, 'handleFlash'),
				'disabled': st.download ? null : 'disabled'
			}, _('刷写并重启'))
		];
		nodes.push(E('div', { 'class': 'cbi-page-actions' }, buttons));

		if (st.check && st.check.remote && st.check.remote.notes)
			nodes.push(E('p', { 'class': 'cbi-section-descr' }, st.check.remote.notes));

		var body = this.bodyNode;
		body.innerHTML = '';
		nodes.forEach(function(n) { body.appendChild(n); });
	},

	render: function(data) {
		this.state = {
			check: data.check || null,
			download: null,
			error: data.error || null
		};
		this.bodyNode = E('div', { 'class': 'cbi-map' });

		var root = E('div', {}, [
			E('h2', {}, _('固件在线升级')),
			E('div', { 'class': 'cbi-map-descr' },
				_('从本项目的发布地址获取新固件，校验 sha256 后一键刷写。刷写默认保留配置（含 WireGuard 私钥、IPv6 与插件设置）。')),
			this.bodyNode
		]);

		this.paint();

		return root;
	}
});
