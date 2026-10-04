--!strict
--!native
-- Executable OpenMW knowledge. Stable review policy lives here; factual engine contracts are generated
-- from the supplied OpenMW source tree in @openmw/workbench/contract.
local contract = require '@openmw/workbench/contract'

local RuntimeContexts = { 'global', 'local', 'player', 'menu' }
local AllContexts = { 'global', 'local', 'player', 'menu', 'load' }

local ApiContexts = {}
for moduleName, module in contract.modules do
  ApiContexts[moduleName] = module.contexts
end

local RuleDocs = {
  ['context.invalid'] = {
    source = 'OpenMW configuration.cpp script-context grammar',
    docs = 'OpenMW script configuration contexts',
  },
  ['context.unresolved'] = {
    source = 'OpenMW package contract + openmw-context-check',
    docs = 'cod3x/docs/getting-started/contexts.md',
    skill = 'openmw-lua-context-guard',
  },
  ['context.unknown-api'] = {
    source = 'OpenMW files/lua_api/openmw/*.lua + MWLua package registration',
    docs = 'OpenMW Lua API specification',
  },
  ['context.probe'] = {
    source = 'OpenMW package contract + Cod3x anti-patterns',
    docs = 'cod3x/docs/anti-patterns/context-probing.md',
    skill = 'openmw-lua-context-guard',
  },
  ['context.api'] = {
    source = 'OpenMW files/lua_api/openmw + MWLua package registration',
    docs = 'cod3x/docs/getting-started/contexts.md',
    skill = 'openmw-lua-context-guard',
  },
  ['context.require-boundary'] = {
    source = 'Jess local require graph + explicit @omw-context contracts',
    docs = 'cod3x/docs/getting-started/contexts.md',
    skill = 'openmw-lua-context-guard',
  },
  ['api.unknown-member'] = {
    source = 'OpenMW files/lua_api/openmw/*.lua',
    docs = 'OpenMW Lua API specification',
  },
  ['api.engine-internal'] = {
    source = 'OpenMW shipped Lua + files/lua_api/openmw/*.lua',
    docs = 'OpenMW Lua API specification',
  },
  ['api.member-context'] = {
    source = 'OpenMW MWLua package construction',
    docs = 'cod3x/docs/getting-started/contexts.md',
    skill = 'openmw-lua-context-guard',
  },
  ['api.arity'] = {
    source = 'OpenMW files/lua_api/openmw/*.lua',
    docs = 'OpenMW Lua API specification',
  },
  ['handler.unknown'] = {
    source = 'OpenMW MWLua EngineHandlerList registrations',
    docs = 'cod3x/docs/getting-started/mental-model.md',
  },
  ['handler.context'] = {
    source = 'OpenMW MWLua EngineHandlerList registrations',
    docs = 'cod3x/docs/getting-started/mental-model.md',
  },
  ['handler.signature'] = {
    source = 'OpenMW MWLua callEngineHandlers call sites',
    docs = 'cod3x/docs/getting-started/mental-model.md',
  },
  ['handler.indirect'] = {
    source = 'Jess Luau semantic index + OpenMW handler registrations',
    docs = 'cod3x/docs/getting-started/mental-model.md',
  },
  ['lifecycle.save-pair'] = {
    source = 'OpenMW ScriptsContainer save/load contract',
    docs = 'cod3x/docs/practice/save-compatibility.md',
    skill = 'openmw-persistence-storage-auditor',
  },
  ['lifecycle.unversioned-save'] = {
    source = 'OpenMW onSave/onLoad contract + Cod3x save compatibility policy',
    docs = 'cod3x/docs/practice/save-compatibility.md',
    skill = 'openmw-persistence-storage-auditor',
  },
  ['lifecycle.top-level-openmw'] = {
    source = 'Cod3x lifecycle practice + OpenMW package contract',
    docs = 'cod3x/docs/getting-started/mental-model.md',
    skill = 'openmw-lifecycle-debugger',
  },
  ['storage.readonly-write'] = {
    source = 'OpenMW components/lua/storage.cpp',
    docs = 'cod3x/docs/getting-started/storage-and-lifecycle.md',
    skill = 'openmw-persistence-storage-auditor',
  },
  ['storage.top-level-write'] = {
    source = 'OpenMW storage contract + Cod3x lifecycle policy',
    docs = 'cod3x/docs/getting-started/storage-and-lifecycle.md',
    skill = 'openmw-persistence-storage-auditor',
  },
  ['storage.hot-write'] = {
    source = 'OpenMW storage contract + Cod3x hot-path policy',
    docs = 'cod3x/docs/performance/hot-paths.md',
    skill = 'openmw-performance-hotpath-reviewer',
  },
  ['event.dynamic-name'] = {
    source = 'Jess Luau semantic index + OpenMW event API',
    docs = 'cod3x/docs/practice/events.md',
  },
  ['event.void'] = {
    source = 'openmw-event-bus-check',
    docs = 'cod3x/docs/practice/events.md',
  },
  ['event.never-sent'] = {
    source = 'OpenMW event sender/handler graph',
    docs = 'cod3x/docs/practice/events.md',
  },
  ['interface.context'] = {
    source = 'OpenMW builtin.omwscripts + builtin Lua interface providers',
    docs = 'cod3x/docs/getting-started/events-and-interfaces.md',
  },
  ['interface.name'] = {
    source = 'OpenMW public-interface contract + Cod3x interface naming policy',
    docs = 'cod3x/docs/cookbook/interface-contract.md',
  },
  ['interface.override-chain'] = {
    source = 'OpenMW ScriptsContainer public-interface contract',
    docs = 'cod3x/docs/cookbook/interface-contract.md',
  },
  ['content.record-type'] = {
    source = 'OpenMW types/types.cpp object type map + Dreamwind TES3 record decoding',
    docs = 'OpenMW Lua object type contract',
  },
  ['content.plugin-parse'] = {
    source = 'Dreamwind TES3 decoder',
    docs = 'Dreamwind content parsing',
  },
  ['content.nif-parse'] = {
    source = 'Dreamwind NIF decoder + OpenMW VFS resolution',
    docs = 'Dreamwind NIF parsing',
  },
  ['ui.layer'] = {
    source = 'OpenMW UI API spec + Cod3x UI policy',
    docs = 'cod3x/docs/getting-started/ui.md',
    skill = 'openmw-ui-layout-author',
  },
  ['performance.allocation'] = {
    source = 'Jess Luau AST + OpenMW hot-handler registrations',
    docs = 'cod3x/docs/performance/hot-paths.md',
    skill = 'openmw-performance-hotpath-reviewer',
  },
  ['performance.closure'] = {
    source = 'Jess Luau AST + OpenMW hot-handler registrations',
    docs = 'cod3x/docs/performance/hot-paths.md',
    skill = 'openmw-performance-hotpath-reviewer',
  },
}

local Profiles = {
  default = {
    'context', 'api', 'handlers', 'lifecycle', 'storage', 'events', 'interfaces', 'ui', 'performance', 'content',
  },
  context = { 'context', 'api', 'interfaces' },
  lifecycle = { 'handlers', 'lifecycle', 'events' },
  persistence = { 'handlers', 'lifecycle', 'storage' },
  events = { 'events', 'handlers', 'interfaces' },
  ui = { 'ui', 'events', 'lifecycle', 'api' },
  performance = { 'performance', 'storage', 'handlers' },
  api = { 'context', 'api', 'handlers', 'interfaces' },
  content = { 'content' },
  all = {
    'context', 'api', 'handlers', 'lifecycle', 'storage', 'events', 'interfaces', 'ui', 'performance', 'content',
  },
}

local function moduleContract(moduleName: string)
  return contract.modules[moduleName]
end

local function memberContract(moduleName: string, member: string)
  local module = contract.modules[moduleName]
  return module and module.members[member] or nil
end

return table.freeze {
  allContexts = AllContexts,
  runtimeContexts = RuntimeContexts,
  apiContexts = table.freeze(ApiContexts),
  engineHandlers = contract.engineHandlers,
  storageMutability = contract.storageMutability,
  ruleDocs = table.freeze(RuleDocs),
  profiles = table.freeze(Profiles),
  contract = contract,
  moduleContract = moduleContract,
  memberContract = memberContract,
}
