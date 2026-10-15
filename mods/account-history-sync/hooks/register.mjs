import { createController } from './controller.mjs';
import { renderBand, renderPane, renderLauncher, launcherVisible } from './ui.mjs';

const PANE = 'history-sync';
const HELP = 'Open History sync above the prompt or use /history-sync. Optional commands: accounts, backups, profiles, to <inactive-destination-email-or-id>, preview, sync, start, pause, status. Pause before switching accounts.';

export function register(on) {
  const controller = createController();
  on('session.start', async ($, e, next) => {
    const adapter = {
      root: $.plugin.root,
      windows: (await $.env.get('OS')) === 'Windows_NT',
      processRun: (argv, options) => $.process.run(argv, options),
      redraw: () => $.ui.invalidate('ui.render'),
      log: text => $.ui.log(text),
      now: () => $.clock.now(),
      sessionId: () => $.session.id(),
      envGet: () => $.env.get('ACCOUNT_HISTORY_SYNC_CONFIG'),
      storeGet: key => $.store.get(key),
      storeSet: (key, value) => $.store.set(key, value),
      every: (ms, fn) => $.clock.every(ms, fn),
      after: (ms, fn) => $.clock.after(ms, fn),
    };
    await controller.initialize(adapter);
    await $.command.register({ name: 'history-sync', description: 'Manage local account history sync', argumentHint: '[accounts|backups|to|preview|sync|start|pause|status]', immediate: true });
    return next(e);
  });
  on('session.end', async ($, e, next) => {
    controller.stop();
    // No last-minute writes on logout, resume, clear, or shutdown.
    return next(e);
  });
  on('turn.complete', async ($, e, next) => {
    const result = await next(e);
    if (!e.agentId) { await controller.reopen(); controller.afterTurn(); }
    return result;
  });
  on('command.run', { command: 'history-sync' }, async ($, e) => {
    const args = (e.args || '').trim().split(/\s+/).filter(Boolean);
    try {
      await controller.reopen();
      switch (args[0] || '') {
        case '': case 'accounts': case 'backups':
          if (args[0]) controller.showSection(args[0]);
          if (!controller.view.source || !controller.view.target) controller.showSection(args[0] === 'backups' ? 'backups' : 'accounts');
          await $.ui.open({ id: PANE, title: 'History sync', focus: true, closeOnEscape: true });
          await controller.refresh();
          return {};
        case 'profiles': {
          await controller.refresh();
          return { text: controller.view.profiles.map(p => `${p.Email || p.Label} | ${p.Id} | ${p.Sessions} sessions`).join('\n') || controller.statusText() };
        }
        case 'to':
          if (args.length !== 2) return { text: HELP };
          await controller.refresh();
          await controller.choose(controller.view.source, controller.resolveSelector(args[1]));
          return { text: controller.statusText() };
        case 'pair': // Compatibility: cannot replace an already identified current source.
          if (args.length !== 3) return { text: HELP };
          await controller.refresh();
          await controller.choose(controller.resolveSelector(args[1]), controller.resolveSelector(args[2]));
          return { text: controller.statusText() };
        case 'preview': await controller.preview(); return { text: controller.statusText() };
        case 'sync': await controller.sync(); return { text: controller.statusText() };
        case 'start': await controller.start(); return { text: controller.statusText() };
        case 'pause': await controller.pause(); return { text: controller.statusText() };
        case 'status': return { text: controller.statusText() };
        default: return { text: HELP };
      }
    } catch (error) { return { text: error.message }; }
  });
  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e);
    const { Box, Text, Button, Select, Input } = $.ui.resolve(e);
    return renderPane({ Box, Text, Button, Select, Input }, controller,
      (text, surface) => $.ui.copy({ text, surface: surface || e.surface }));
  });
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const existing = await next(e);
    if (e.props?.hasSurvey || e.props?.view?.agentId || !launcherVisible(controller.view, 'band')) return existing;
    const { Box, Text, Button } = $.ui.resolve(e);
    return Box({ flexDirection: 'column', children: [existing,
      renderBand({ Box, Text, Button }, controller, async () => {
        await controller.reopen();
        if (!controller.view.source || !controller.view.target) controller.showSection('accounts');
        await $.ui.open({ id: PANE, title: 'History sync', focus: true, closeOnEscape: true });
        await controller.refresh();
      }),
    ] });
  });
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const existing = await next(e);
    if (!launcherVisible(controller.view, 'mode')) return existing;
    const { Box, Button } = $.ui.resolve(e);
    return Box({ flexDirection: 'row', flexWrap: 'wrap', gap: 1, children: [existing,
      renderLauncher({ Box, Button }, controller, async () => {
        await controller.reopen();
        if (!controller.view.source || !controller.view.target) controller.showSection('accounts');
        await $.ui.open({ id: PANE, title: 'History sync', focus: true, closeOnEscape: true });
        await controller.refresh();
      }, 'mode'),
    ] });
  });
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    const existing = await next(e);
    if (!launcherVisible(controller.view, 'hint')) return existing;
    const { Box, Button } = $.ui.resolve(e);
    return Box({ flexDirection: 'row', flexWrap: 'wrap', gap: 1, children: [existing,
      renderLauncher({ Box, Button }, controller, async () => {
        await controller.reopen();
        if (!controller.view.source || !controller.view.target) controller.showSection('accounts');
        await $.ui.open({ id: PANE, title: 'History sync', focus: true, closeOnEscape: true });
        await controller.refresh();
      }, 'hint'),
    ] });
  });
}
