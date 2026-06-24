'use strict';
'require ui';
'require view';
'require dom';
'require poll';
'require uci';
'require fs';
'require form';
'require rpc';

function callManager(command, sid) {
	var args = [];
	var cmdParts = command.split(' ');

	args.push(cmdParts[0]);
	if (cmdParts[1])
		args.push(cmdParts[1]);
	if (sid)
		args.push(sid);

	return fs.exec('/usr/bin/uestc_authclient_manager.sh', args).then(function(res) {
		if (res.code !== 0)
			throw new Error('Manager script execution failed: ' + (res.stderr || res.stdout || 'Unknown error'));

		switch (cmdParts[0]) {
		case 'status':
			try {
				var parsedData = JSON.parse(res.stdout);
				if (parsedData && Array.isArray(parsedData.sessions))
					return parsedData.sessions;

				console.warn('Received status data is not in the expected { sessions: [...] } format:', parsedData);
				return [];
			}
			catch (e) {
				console.error('Failed to parse JSON status:', res.stdout, e);
				throw new Error('Failed to parse status JSON: ' + e.message);
			}

		case 'log':
			return res.stdout || '';

		case 'start':
		case 'stop':
		case 'restart':
		case 'clean':
			return true;

		default:
			throw new Error('Unknown command: ' + command);
		}
	}).catch(function(err) {
		ui.addNotification(null, E('p', _('Error executing command:') + ' ' + err.message));
		return Promise.reject(err);
	});
}

function hasClass(node, className) {
	return node && node.className && (' ' + node.className + ' ').indexOf(' ' + className + ' ') >= 0;
}

function closestByClass(node, className) {
	while (node) {
		if (node.nodeType === 1 && hasClass(node, className))
			return node;
		node = node.parentNode;
	}
	return null;
}

function setButtonsDisabled(row, disabled) {
	if (!row)
		return;

	var buttons = row.querySelectorAll('.start-stop, .restart, .cbi-button-edit, .cbi-button-remove');
	for (var i = 0; i < buttons.length; i++)
		buttons[i].disabled = disabled;
}

function sessionNames() {
	var sections = uci.sections('uestc_authclient', 'session');
	var names = [];

	for (var i = 0; i < sections.length; i++)
		names.push(sections[i]['.name']);

	return names;
}

return view.extend({
	datestr: function(ts) {
		if (!ts || ts <= 0)
			return _('None');

		var date = new Date(ts * 1000);
		return date.toLocaleString();
	},

	callInitAction: rpc.declare({
		object: 'luci',
		method: 'setInitAction',
		params: ['name', 'action'],
		expect: { result: false }
	}),

	callGetStatus: function(sid) {
		return callManager('status', sid);
	},

	callStartSession: function(sid) {
		return callManager('start', sid);
	},

	callStopSession: function(sid) {
		return callManager('stop', sid);
	},

	callRestartSession: function(sid) {
		return callManager('restart', sid);
	},

	callGetLogs: function(sid) {
		return callManager('log', sid);
	},

	callCleanLogs: function(sid) {
		return callManager('clean log', sid);
	},

	callCleanSession: function(sid) {
		return callManager('clean all', sid);
	},

	load: function() {
		return Promise.all([
			uci.load('uestc_authclient'),
			this.callGetStatus()
		]);
	},

	render: function(data) {
		var initialStatus = data[1] || [];
		var self = this;
		var m, s, o;

		function toggleLogDisplay(section_id) {
			var logDisplay = document.getElementById(section_id + '_log_display_area');
			if (!logDisplay) {
				console.error(section_id + ' log display area not found');
				return;
			}

			if (logDisplay.style.display === 'none') {
				logDisplay.style.display = 'block';
				loadLogs(section_id, logDisplay);
			}
			else {
				logDisplay.style.display = 'none';
			}
		}

		function loadLogs(logDomain, logDisplay) {
			logDisplay.value = _('Loading logs...');
			self.callGetLogs(logDomain).then(function(logText) {
				logDisplay.value = logText || _('No logs available');
				logDisplay.scrollTop = logDisplay.scrollHeight;
			}).catch(function(e) {
				console.error('Error loading logs:', e);
				logDisplay.value = _('Failed to load logs.') + ' ' + e.message;
			});
		}

		function createLogDisplayArea(section_id) {
			return function() {
				var areaId = section_id + '_log_display_area';
				var textarea = E('textarea', {
					id: areaId,
					rows: 20,
					readonly: 'readonly',
					wrap: 'off',
					'class': 'cbi-input-textarea',
					style: ['width:100%', 'box-sizing:border-box', 'display:none'].join(';')
				});

				return E('div', {
					style: ['display:flex', 'justify-content:center', 'padding:8px 0'].join(';')
				}, [textarea]);
			};
		}

		m = new form.Map(
			'uestc_authclient',
			_('UESTC Authentication Client'),
			_('This page displays the current status of the UESTC authentication client. Please adjust other settings as needed.')
		);

		s = m.section(form.NamedSection, 'global', 'system');
		s.tab('info', _('Status & Control'));
		s.tab('global_settings', _('Global Settings'));

		o = s.taboption('info', form.Flag, 'enabled', _('Bring up on boot'));
		o.description = _('Check to run the service automatically at system startup.');
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('info', form.Button, '_restart');
		o.title = '&#160;';
		o.inputstyle = 'reload';
		o.inputtitle = _('Restart Service');
		o.onclick = function() {
			ui.showModal(_('Confirm Action'), [
				E('p', _('Restart the UESTC Auth service?')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', click: ui.hideModal }, _('Cancel')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-positive important',
						click: function() {
							return self.callInitAction('uestc_authclient', 'restart').then(function() {
								window.location.reload();
							}).catch(function(e) {
								ui.addNotification(null, E('p', e.message));
							});
						}
					}, _('Restart Service'))
				])
			]);
		};

		o = s.taboption('info', form.Button, '_show_global_log');
		o.title = _('Global Logs');
		o.inputstyle = 'apply';
		o.inputtitle = _('Read/Reread log file');
		o.onclick = function() {
			toggleLogDisplay('global');
		};

		o = s.taboption('info', form.DummyValue, '_global_log_display');
		o.render = createLogDisplayArea('global');

		o = s.taboption('global_settings', form.Value, 'log_rdays', _('Log retention days (Global)'));
		o.description = _('Specify the number of days to retain global log files.');
		o.datatype = 'uinteger';
		o.placeholder = '7';

		o = s.taboption('global_settings', form.Button, '_clean_log');
		o.title = _('Clean Logs');
		o.inputtitle = _('Delete');
		o.inputstyle = 'reset';
		o.onclick = function() {
			self.callCleanLogs('global').then(function() {
				ui.addNotification(null, E('p', _('Global logs have been successfully cleared.')));
			}).catch(function(err) {
				ui.addNotification(null, E('p', _('Error clearing global logs: ') + err.message));
			});
		};

		s = m.section(form.GridSection, 'session', _('Authentication Sessions'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.addbtntitle = _('Add new session...');

		o = s.option(form.DummyValue, '_cfg_name', _('Name'));
		o.textvalue = function(section_id) {
			return '<b>' + section_id + '</b>';
		};

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.Value, 'listen_interface', _('Interface'));
		o = s.option(form.DummyValue, '_cfg_status', _('Status'));
		o = s.option(form.DummyValue, '_cfg_network', _('Network Status'));
		o = s.option(form.DummyValue, '_cfg_last_login', _('Last Login Time'));

		s.handleAdd = function() {
			var section = this;
			var map = section.map;
			var existingSids = sessionNames();
			var inputSid = E('input', { id: 'new_sid', type: 'text', style: 'width:100%; margin-top:8px;' });
			var errorMsg = E('div', { style: 'display:none; color:#d9534f; margin-top:4px;' });
			var btnCreate = E('button', { 'class': 'cbi-button cbi-button-positive important', disabled: true }, _('Create'));

			function validateSid(sid, existing) {
				if (!sid)
					return _('Session name cannot be empty.');
				if (['global', 'basic', '_new_', 'lock'].indexOf(sid) >= 0)
					return _('This name is reserved, please choose another.');
				if (!/^[A-Za-z0-9_-]{1,32}$/.test(sid))
					return _('Only letters, numbers, "-" and "_" are allowed (1-32 chars).');
				if (existing.indexOf(sid) >= 0)
					return _('Session name already exists.');
				return null;
			}

			function refreshValidation() {
				var sid = inputSid.value.replace(/^\s+|\s+$/g, '');
				var info = validateSid(sid, existingSids);

				if (info) {
					errorMsg.textContent = info;
					errorMsg.style.display = 'block';
					btnCreate.disabled = true;
				}
				else {
					errorMsg.style.display = 'none';
					btnCreate.disabled = false;
				}
			}

			inputSid.addEventListener('input', refreshValidation);
			btnCreate.addEventListener('click', function() {
				var sid = inputSid.value.replace(/^\s+|\s+$/g, '');
				var err = validateSid(sid, existingSids);
				if (err) {
					refreshValidation();
					return;
				}

				uci.add('uestc_authclient', 'session', sid);
				ui.hideModal();

				map.render().then(function(nodes) {
					var row = nodes.querySelector('.cbi-section-table-row[data-sid="' + sid + '"]');
					var editButton = row ? row.querySelector('.cbi-button-edit') : null;
					if (editButton)
						editButton.click();
				});
			});

			ui.showModal(_('Add new session...'), [
				E('p', _('Please enter a new session name: (avoid using reserved names like "global")')),
				inputSid,
				errorMsg,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', click: ui.hideModal }, _('Cancel')),
					' ',
					btnCreate
				])
			]);

			inputSid.focus();
		};

		s.modaltitle = function(section_id) {
			return _('Session Configuration') + ' >> ' + section_id;
		};

		s.addModalOptions = function(modalSection, section_id) {
			modalSection.tab('auth', _('Authentication Settings'));
			modalSection.tab('network', _('Network Settings'));
			modalSection.tab('schedule', _('Scheduled Disconnection'));
			modalSection.tab('logging', _('Logging Settings'));

			o = modalSection.taboption('auth', form.Flag, 'enabled', _('Enabled'));
			o.default = '0';
			o.rmempty = false;

			o = modalSection.taboption('auth', form.Flag, 'lm_enabled', _('Limited Monitoring'));
			o.description = _('Check to limit monitoring and reconnection attempts to within 10 minutes around the last login time.');
			o.default = '0';
			o.rmempty = false;

			o = modalSection.taboption('auth', form.ListValue, 'auth_type', _('Authentication method'));
			o.description = _('Select the authentication method.<br />') +
				_('<strong>CT authentication method is the legacy China Telecom portal.</strong><br />') +
				_('电信锐捷认证 is the new 110.184.24.61 CAS/Ruijie portal.');
			o.value('srun', _('Srun authentication method (go-nd-portal)'));
			o.value('ct', _('CT authentication method (legacy qsh-telecom-autologin)'));
			o.value('qsh-telecom-ruijie', _('电信锐捷认证 (qsh-telecom-ruijie)'));
			o.default = 'srun';
			o.rmempty = false;

			o = modalSection.taboption('auth', form.ListValue, 'auth_mode', _('Srun authentication mode'));
			o.description = _('Select the authentication mode for the Srun client.');
			o.value('qsh-edu', _('Qingshuihe Campus') + ' - ' + _('CERNET'));
			o.value('qsh-dx', _('Qingshuihe Campus') + ' - ' + _('China Telecom'));
			o.value('qshd-dx', _('Qingshuihe Campus Dormitory') + ' - ' + _('China Telecom'));
			o.value('qshd-cmcc', _('Qingshuihe Campus Dormitory') + ' - ' + _('China Mobile'));
			o.value('sh-edu', _('Shahe Campus') + ' - ' + _('CERNET'));
			o.value('sh-dx', _('Shahe Campus') + ' - ' + _('China Telecom'));
			o.value('sh-cmcc', _('Shahe Campus') + ' - ' + _('China Mobile'));
			o.default = 'qsh-edu';
			o.depends('auth_type', 'srun');

			o = modalSection.taboption('auth', form.Value, 'auth_username', _('Username'));
			o.description = _('Your authentication username.');
			o.placeholder = _('Required');
			o.rmempty = false;
			o.validate = function(section_id, value) {
				if (!value)
					return _('Username cannot be empty.');
				return true;
			};

			o = modalSection.taboption('auth', form.Value, 'auth_password', _('Password'));
			o.description = _('Your authentication password.');
			o.password = true;
			o.placeholder = _('Required');
			o.rmempty = false;
			o.validate = function(section_id, value) {
				if (!value)
					return _('Password cannot be empty.');
				return true;
			};

			o = modalSection.taboption('auth', form.ListValue, 'auth_host', _('Authentication Host'));
			o.description = _('Authentication server address, modify according to your area.');
			o.datatype = 'ip4addr';
			o.value('172.25.249.64', _('China Telecom') + ' - ' + _('Qingshuihe Campus Dormitory') + ' (172.25.249.64)');
			o.value('110.184.24.61', _('锐捷') + ' - ' + _('清水河宿舍') + ' (110.184.24.61)');
			o.value('10.253.0.237', 'Srun - ' + _('Qingshuihe Campus') + ' (10.253.0.237)');
			o.value('10.253.0.235', 'Srun - ' + _('Qingshuihe Campus Dormitory') + ' (10.253.0.235)');
			o.value('192.168.9.8', 'Srun - ' + _('Shahe Campus') + ' (192.168.9.8)');
			o.rmempty = false;

			o = modalSection.taboption('network', form.Value, 'listen_interface', _('Interface'));
			o.description = _('Select the interface for authentication. (Linux Interface, Refers to Device in Openwrt.)');
			o.default = 'wan';
			o.placeholder = 'wan';
			o.validate = function(section_id, value) {
				var sections = uci.sections('uestc_authclient', 'session');
				for (var i = 0; i < sections.length; i++) {
					if (sections[i]['.name'] !== section_id && sections[i].listen_interface === value && sections[i].enabled === '1')
						return _('This interface is already in use in another session!');
				}
				return true;
			};
			o.rmempty = false;

			o = modalSection.taboption('network', form.DynamicList, 'listen_hosts', _('Heartbeat hosts'));
			o.description = _('Host addresses used to check network connectivity; you can add multiple addresses.');
			o.datatype = 'ip4addr';
			o.default = ['223.5.5.5', '119.29.29.29'];
			o.placeholder = '223.5.5.5';
			o.rmempty = false;

			o = modalSection.taboption('network', form.Value, 'listen_check_interval', _('Check interval (seconds)'));
			o.description = _('Time interval for checking network status, in seconds.');
			o.datatype = 'uinteger';
			o.default = '30';
			o.placeholder = '30';
			o.rmempty = false;

			o = modalSection.taboption('schedule', form.Flag, 'schedule_enabled', _('Enable scheduled disconnection'));
			o.description = _('Check to disconnect the network during specified time periods.');
			o.default = '0';
			o.rmempty = false;

			o = modalSection.taboption('schedule', form.Value, 'schedule_start', _('Disconnection start time (hour)'));
			o.datatype = 'range(0,23)';
			o.default = '3';
			o.placeholder = '3';
			o.rmempty = false;
			o.depends('schedule_enabled', '1');

			o = modalSection.taboption('schedule', form.Value, 'schedule_end', _('Disconnection end time (hour)'));
			o.datatype = 'range(0,23)';
			o.default = '4';
			o.placeholder = '4';
			o.rmempty = false;
			o.depends('schedule_enabled', '1');
			o.validate = function(section_id, value) {
				var start = this.section.formvalue(section_id, 'schedule_start');
				if (start && value && start === value)
					return _('Disconnection start time and end time cannot be the same!');
				return true;
			};

			o = modalSection.taboption('logging', form.Value, 'log_rdays', _('Log retention days (Session)'));
			o.description = _('Specify the number of days to retain session log files.');
			o.datatype = 'uinteger';
			o.default = '7';
			o.placeholder = '7';
			o.rmempty = false;

			o = modalSection.taboption('logging', form.Button, '_read_log');
			o.title = _('Log Viewer');
			o.inputtitle = _('Read/Reread log file');
			o.inputstyle = 'apply';
			o.onclick = function() {
				toggleLogDisplay(section_id);
			};

			o = modalSection.taboption('logging', form.DummyValue, '_log_display');
			o.modalonly = true;
			o.render = createLogDisplayArea(section_id);

			o = modalSection.taboption('logging', form.Button, '_clean_log');
			o.title = _('Clean Logs');
			o.inputtitle = _('Delete');
			o.inputstyle = 'reset';
			o.onclick = function() {
				self.callCleanLogs(section_id).then(function() {
					ui.addNotification(null, E('p', _('Logs of session %s have been successfully cleared.').format(section_id)));
				}).catch(function(err) {
					ui.addNotification(null, E('p', _('Error clearing logs of session %s: ').format(section_id) + err.message));
				});
			};

			o = modalSection.taboption('logging', form.Button, '_clean_all');
			o.title = '&#160;';
			o.inputtitle = _('Reset');
			o.inputstyle = 'reset';
			o.description = _('Reset everything but config of current session. This includes session logs, last login record, and network status.');
			o.onclick = function() {
				self.callCleanSession(section_id).then(function() {
					ui.addNotification(null, E('p', _('Session %s have been successfully reset.').format(section_id)));
				}).catch(function(err) {
					ui.addNotification(null, E('p', _('Error resetting session %s: ').format(section_id) + err.message));
				});
			};
		};

		s.renderRowActions = function(section_id) {
			var tdEl = this.super('renderRowActions', [section_id, _('Edit')]);
			var buttonContainer = tdEl.lastChild;
			var firstExistingButton = buttonContainer ? buttonContainer.firstChild : null;
			var startStopBtn = E('button', {
				'class': 'cbi-button cbi-button-action start-stop',
				title: _('Start/Stop this session'),
				disabled: true
			}, _('Loading...'));
			var restartBtn = E('button', {
				'class': 'cbi-button cbi-button-action restart',
				title: _('Restart this session'),
				disabled: true,
				click: function(ev) {
					return self.handleSessionAction(section_id, 'restart', ev);
				}
			}, _('Restart'));
			var space1 = document.createTextNode(' ');
			var space2 = document.createTextNode(' ');

			if (firstExistingButton) {
				buttonContainer.insertBefore(startStopBtn, firstExistingButton);
				buttonContainer.insertBefore(space1, firstExistingButton);
				buttonContainer.insertBefore(restartBtn, firstExistingButton);
				buttonContainer.insertBefore(space2, firstExistingButton);
			}
			else if (buttonContainer) {
				dom.append(buttonContainer, [startStopBtn, space1, restartBtn, space2]);
			}

			return tdEl;
		};

		return m.render().then(function(nodes) {
			self.poll_status(nodes, initialStatus);
			poll.add(function() {
				return self.callGetStatus().then(function(sessionsStatus) {
					self.poll_status(nodes, sessionsStatus);
				});
			}, 5);

			return nodes;
		});
	},

	handleSessionAction: function(sid, action, ev) {
		var self = this;
		var targetButton = ev && (ev.currentTarget || ev.target);
		var row = closestByClass(targetButton, 'cbi-section-table-row');
		var nodes = closestByClass(targetButton, 'cbi-map');
		var promise;

		setButtonsDisabled(row, true);

		switch (action) {
		case 'start':
			promise = this.callStartSession(sid);
			break;
		case 'stop':
			promise = this.callStopSession(sid);
			break;
		case 'restart':
			promise = this.callRestartSession(sid);
			break;
		default:
			promise = Promise.reject('Invalid action');
			break;
		}

		return promise.then(function() {
			return new Promise(function(resolve) {
				window.setTimeout(resolve, 500);
			});
		}).then(function() {
			return self.callGetStatus().then(function(sessionsStatus) {
				if (nodes)
					self.poll_status(nodes, sessionsStatus);
			});
		}).catch(function(err) {
			console.error('Session action failed:', err);
			ui.addNotification(null, E('p', _('Action failed: %s').format(err.message || err)));

			return self.callGetStatus().then(function(sessionsStatus) {
				if (nodes)
					self.poll_status(nodes, sessionsStatus);
			});
		}).then(function(result) {
			setButtonsDisabled(row, false);
			return result;
		}, function(err) {
			setButtonsDisabled(row, false);
			return Promise.reject(err);
		});
	},

	poll_status: function(nodes, statusData) {
		var gridRows = nodes.querySelectorAll('.cbi-section-table-row[data-sid]');
		var statusMap = {};

		if (Array.isArray(statusData)) {
			for (var i = 0; i < statusData.length; i++)
				statusMap[statusData[i].sid] = statusData[i];
		}

		for (var r = 0; r < gridRows.length; r++) {
			var row = gridRows[r];
			var sid = row.getAttribute('data-sid');
			var status = statusMap[sid];
			var statusCell = row.querySelector('[data-name="_cfg_status"]');
			var networkCell = row.querySelector('[data-name="_cfg_network"]');
			var loginCell = row.querySelector('[data-name="_cfg_last_login"]');
			var startStopBtn = row.querySelector('.cbi-button.start-stop');
			var restartBtn = row.querySelector('.cbi-button.restart');

			if (!startStopBtn || !restartBtn) {
				console.warn('Buttons not found for SID: ' + sid);
				continue;
			}

			if (status) {
				dom.content(statusCell, status.running
					? E([], [E('strong', { style: 'color:green' }, _('Running')), ' (PID: ' + status.pid + ')'])
					: E('strong', { style: 'color:red' }, _('Not running')));

				if (status.running) {
					dom.content(networkCell, status.network_up
						? E('strong', { style: 'color:green' }, _('Connected'))
						: E('strong', { style: 'color:red' }, _('Disconnected')));
				}
				else {
					dom.content(networkCell, E('em', _('Not running')));
				}

				dom.content(loginCell, E(status.last_login !== 0 ? 'p' : 'em', this.datestr(status.last_login)));

				startStopBtn.textContent = status.running ? _('Stop') : _('Start');
				startStopBtn.onclick = this.handleSessionAction.bind(this, sid, status.running ? 'stop' : 'start');
				startStopBtn.disabled = false;
				restartBtn.disabled = !status.running;
			}
			else {
				dom.content(statusCell, E('em', _('Unknown')));
				dom.content(networkCell, E('em', _('Unknown')));
				dom.content(loginCell, E('em', _('Unknown')));
				startStopBtn.textContent = _('Start');
				startStopBtn.onclick = null;
				startStopBtn.disabled = true;
				restartBtn.disabled = true;
			}
		}
	}
});
