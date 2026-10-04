--!strict
--!native
-- Executable OpenMW knowledge distilled from the Cod3x corpus and the former OpenCode tools.
local RuntimeContexts = { 'global', 'local', 'player', 'menu' }
local AllContexts = { 'global', 'local', 'player', 'menu', 'load' }

local ApiContexts = {
  ['openmw.async'] = AllContexts,
  ['openmw.core'] = AllContexts,
  ['openmw.markup'] = AllContexts,
  ['openmw.storage'] = AllContexts,
  ['openmw.util'] = AllContexts,
  ['openmw.vfs'] = AllContexts,
  ['openmw.types'] = { 'global', 'local', 'player' },
  ['openmw.interfaces'] = RuntimeContexts,
  ['openmw.content'] = { 'load' },
  ['openmw.world'] = { 'global' },
  ['openmw.animation'] = { 'local', 'player' },
  ['openmw.nearby'] = { 'local', 'player' },
  ['openmw.self'] = { 'local', 'player' },
  ['openmw.ambient'] = { 'player', 'menu' },
  ['openmw.input'] = { 'player', 'menu' },
  ['openmw.ui'] = { 'player', 'menu' },
  ['openmw.camera'] = { 'player' },
  ['openmw.debug'] = { 'player' },
  ['openmw.postprocessing'] = { 'player' },
  ['openmw.menu'] = { 'menu' },
}

local EngineHandlers = {
  onInterfaceOverride = { contexts = AllContexts, minArgs = 1, maxArgs = 1 },
  onInit = { contexts = AllContexts, minArgs = 0, maxArgs = 1 },
  onUpdate = { contexts = AllContexts, minArgs = 0, maxArgs = 1, hot = true },
  onSave = { contexts = AllContexts, minArgs = 0, maxArgs = 0 },
  onLoad = { contexts = AllContexts, minArgs = 1, maxArgs = 2 },
  onNewGame = { contexts = { 'global' }, minArgs = 0, maxArgs = 0 },
  onPlayerAdded = { contexts = { 'global' }, minArgs = 1, maxArgs = 1 },
  onObjectActive = { contexts = { 'global' }, minArgs = 1, maxArgs = 1 },
  onActorActive = { contexts = { 'global' }, minArgs = 1, maxArgs = 1 },
  onItemActive = { contexts = { 'global' }, minArgs = 1, maxArgs = 1 },
  onActivate = { contexts = { 'global' }, minArgs = 2, maxArgs = 2 },
  _onUseItem = { contexts = { 'global' }, minArgs = 3, maxArgs = 3 },
  onNewExterior = { contexts = { 'global' }, minArgs = 1, maxArgs = 1 },
  onActive = { contexts = { 'local', 'player' }, minArgs = 0, maxArgs = 0 },
  onInactive = { contexts = { 'local', 'player' }, minArgs = 0, maxArgs = 0 },
  onTeleported = { contexts = { 'local', 'player' }, minArgs = 0, maxArgs = 0 },
  onActivated = { contexts = { 'local', 'player' }, minArgs = 1, maxArgs = 1 },
  onConsume = { contexts = { 'local', 'player' }, minArgs = 1, maxArgs = 1 },
  _onAnimationTextKey = { contexts = { 'local', 'player' }, minArgs = 2, maxArgs = 2 },
  _onPlayAnimation = { contexts = { 'local', 'player' }, minArgs = 2, maxArgs = 2 },
  _onAnimationEnded = { contexts = { 'local', 'player' }, minArgs = 5, maxArgs = 5 },
  _onSkillUse = { contexts = { 'local', 'player' }, minArgs = 3, maxArgs = 3 },
  _onSkillLevelUp = { contexts = { 'local', 'player' }, minArgs = 2, maxArgs = 2 },
  _onJailTimeServed = { contexts = { 'local', 'player' }, minArgs = 1, maxArgs = 1 },
  onFrame = { contexts = { 'player', 'menu' }, minArgs = 0, maxArgs = 1, hot = true },
  onKeyPress = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onKeyRelease = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onControllerButtonPress = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onControllerButtonRelease = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onInputAction = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onTouchPress = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onTouchRelease = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onTouchMove = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onMouseButtonPress = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onMouseButtonRelease = { contexts = { 'player', 'menu' }, minArgs = 1, maxArgs = 1 },
  onMouseWheel = { contexts = { 'player', 'menu' }, minArgs = 2, maxArgs = 2 },
  onConsoleCommand = { contexts = { 'player', 'menu' }, minArgs = 2, maxArgs = 3 },
  onQuestUpdate = { contexts = { 'player' }, minArgs = 2, maxArgs = 2 },
  _onUiModeChanged = { contexts = { 'player', 'menu' }, minArgs = 0, maxArgs = 2 },
  onStateChanged = { contexts = { 'menu' }, minArgs = 0, maxArgs = 0 },
  onContentFilesLoaded = { contexts = { 'load' }, minArgs = 0, maxArgs = 0 },
}

local RuleDocs = {
  ['context.missing'] = {
    source = 'openmw-context-check',
    docs = 'cod3x/docs/getting-started/contexts.md',
    skill = 'openmw-lua-context-guard',
  },
  ['context.probe'] = {
    source = 'openmw-context-check + Cod3x anti-patterns',
    docs = 'cod3x/docs/anti-patterns/context-probing.md',
    skill = 'openmw-lua-context-guard',
  },
  ['context.api'] = {
    source = 'openmw-context-check',
    docs = 'cod3x/docs/getting-started/contexts.md',
    skill = 'openmw-lua-context-guard',
  },
  ['handler.unknown'] = {
    source = 'openmw-engine-handler-check',
    docs = 'cod3x/docs/getting-started/mental-model.md',
  },
  ['handler.signature'] = {
    source = 'openmw-engine-handler-check',
    docs = 'cod3x/docs/getting-started/mental-model.md',
  },
  ['lifecycle.save-pair'] = {
    source = 'openmw-save-contract-check',
    docs = 'cod3x/docs/practice/save-compatibility.md',
    skill = 'openmw-persistence-storage-auditor',
  },
  ['lifecycle.top-level-openmw'] = {
    source = 'openmw-lifecycle-check',
    docs = 'cod3x/docs/getting-started/mental-model.md',
    skill = 'openmw-lifecycle-debugger',
  },
  ['storage.hot-write'] = {
    source = 'openmw-storage-audit',
    docs = 'cod3x/docs/performance/hot-paths.md',
    skill = 'openmw-performance-hotpath-reviewer',
  },
  ['event.void'] = {
    source = 'openmw-event-bus-check',
    docs = 'cod3x/docs/practice/events.md',
  },
  ['interface.collision'] = {
    source = 'openmw-interface-check',
    docs = 'cod3x/docs/cookbook/interface-contract.md',
  },
  ['ui.layer'] = {
    source = 'openmw-ui-layout-check',
    docs = 'cod3x/docs/getting-started/ui.md',
    skill = 'openmw-ui-layout-author',
  },
  ['performance.allocation'] = {
    source = 'lua-hotpath-budget-check + openmw-engine-handler-check',
    docs = 'cod3x/docs/performance/hot-paths.md',
    skill = 'openmw-performance-hotpath-reviewer',
  },
}

local Profiles = {
  default = {
    'context', 'handlers', 'lifecycle', 'storage', 'events', 'interfaces', 'ui', 'performance',
  },
  context = { 'context' },
  lifecycle = { 'handlers', 'lifecycle', 'events' },
  persistence = { 'handlers', 'lifecycle', 'storage' },
  events = { 'events', 'handlers', 'interfaces' },
  ui = { 'ui', 'events', 'lifecycle' },
  performance = { 'performance', 'storage', 'handlers' },
  all = {
    'context', 'handlers', 'lifecycle', 'storage', 'events', 'interfaces', 'ui', 'performance',
  },
}

return table.freeze {
  allContexts = AllContexts,
  runtimeContexts = RuntimeContexts,
  apiContexts = table.freeze(ApiContexts),
  engineHandlers = table.freeze(EngineHandlers),
  ruleDocs = table.freeze(RuleDocs),
  profiles = table.freeze(Profiles),
}
