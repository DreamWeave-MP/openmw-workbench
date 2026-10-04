--!strict
--!native
local analysis = require('@jess/style').analysis
local knowledge = require '@openmw/workbench/knowledge'
local model = require '@openmw/workbench/model'

type Finding = {
  code: string,
  category: string,
  severity: 'error' | 'warning' | 'note',
  confidence: 'proven' | 'inferred' | 'heuristic',
  path: string,
  line: number,
  column: number,
  message: string,
  detail: string?,
  provenance: any?,
}

local function contextText(contexts): string
  local list = model.contextList(contexts)
  return if #list == 0 then 'unknown' else table.concat(list, '|')
end

local function finding(code: string, category: string, severity: string, confidence: string, script, line: number, message: string, detail: string?): Finding
  return {
    code = code,
    category = category,
    severity = severity :: any,
    confidence = confidence :: any,
    path = script.path,
    line = line,
    column = 1,
    message = message,
    detail = detail,
    provenance = knowledge.ruleDocs[code],
  }
end

local function hasCategory(enabled, category: string): boolean
  return enabled[category] == true
end

local function enabledCategories(profile: string?)
  local named = profile or 'default'
  local selected = knowledge.profiles[named]
  if not selected then error(`@openmw/workbench: unknown review profile '{named}'`) end
  local enabled = {}
  for _, category in selected do enabled[category] = true end
  return enabled
end

local function allowedContexts(moduleName: string)
  local exact = knowledge.apiContexts[moduleName]
  if exact then return model.contextSet(exact) end
  local head = string.match(moduleName, '^(openmw%.[^.]+)')
  local base = head and knowledge.apiContexts[head]
  return base and model.contextSet(base) or nil
end

local function checkContexts(project, enabled, out)
  if not hasCategory(enabled, 'context') then return end

  for _, script in project.scripts do
    local annotations = script.annotations
    for _, invalid in annotations.invalid do
      table.insert(out, finding(
        'context.invalid', 'context', 'error', 'proven', script, invalid.line,
        `unknown OpenMW context '{invalid.value}'`,
        'Valid context atoms are global, local, player, menu, load, runtime, all, and none.'
      ))
    end

    if #script.openmwRequires > 0 and not annotations.default and #script.manifests == 0 then
      table.insert(out, finding(
        'context.missing', 'context', 'error', 'proven', script, script.openmwRequires[1].line,
        'OpenMW-facing source has no context contract',
        'Add the narrowest correct ---@omw-context annotation or declare the script through an .omwscripts root.'
      ))
    end

    for _, required in script.openmwRequires do
      local allowed = allowedContexts(required.module)
      if not allowed then
        table.insert(out, finding(
          'context.unknown-api', 'context', 'warning', 'inferred', script, required.line,
          `'{required.module}' is not in the workbench OpenMW availability table`,
          'Check the module name/case and update the knowledge table when targeting a newer OpenMW API.'
        ))
        continue
      end

      local used = required.contexts
      local sourceLine = analysis.line(script.source, required.line)
      local protectedProbe = string.find(sourceLine, 'pcall%s*%(%s*require') ~= nil
        or string.find(sourceLine, 'pcall%s+require') ~= nil
      if protectedProbe then
        table.insert(out, finding(
          'context.probe', 'context', 'warning', 'proven', script, required.line,
          `protected require probes OpenMW context with '{required.module}'`,
          'Cod3x treats context probing as an anti-pattern for ordinary modules; prefer explicit context contracts and scoped annotations when possible.'
        ))
        continue
      end

      for context in used do
        if allowed[context] then continue end
        table.insert(out, finding(
          'context.api', 'context', 'error', 'proven', script, required.line,
          `'{required.module}' is unavailable in {context} context`,
          `This require is reachable as {contextText(used)}; the module is available as {contextText(allowed)}.`
        ))
      end
    end
  end

  for _, edge in project.workspace.requireEdges do
    local caller, target = project.byPath[edge.from], project.byPath[edge.to]
    if not caller or not target then continue end
    local callerContexts, callerNone = model.contextInfoForLine(caller.annotations, edge.line)
    local used = if callerNone then caller.contexts else callerContexts or caller.contexts
    if target.annotations.defaultNone then continue end
    local allowed = target.annotations.default
    if not allowed then continue end

    for context in used do
      if allowed[context] then continue end
      table.insert(out, finding(
        'context.require-boundary', 'context', 'error', 'proven', caller, edge.line,
        `local require crosses into a module that excludes {context}`,
        `{edge.module} resolves to {target.path}, whose context contract is {contextText(allowed)}.`
      ))
    end
  end
end

local function functionValue(script, handler)
  local value = handler.value
  if value and value.kind == 'ExprFunction' then return value end
  return nil
end

local function handlerMap(script)
  local map = {}
  for _, handler in script.engineHandlers do map[handler.name] = handler end
  return map
end

local function checkHandlers(project, enabled, out)
  if not hasCategory(enabled, 'handlers') then return end

  for _, script in project.scripts do
    for _, handler in script.engineHandlers do
      local spec = knowledge.engineHandlers[handler.name]
      if not spec then
        table.insert(out, finding(
          'handler.unknown', 'handlers', 'warning', 'proven', script, handler.line,
          `unknown engine handler '{handler.name}'`,
          'Misspelled handler names silently do nothing in OpenMW; confirm this is an intentional private/experimental hook.'
        ))
        continue
      end

      local allowed = model.contextSet(spec.contexts)
      for context in script.contexts do
        if allowed[context] then continue end
        table.insert(out, finding(
          'handler.context', 'handlers', 'error', 'proven', script, handler.line,
          `'{handler.name}' is not valid in {context} context`,
          `Handler contexts: {contextText(allowed)}; script contexts: {contextText(script.contexts)}.`
        ))
      end

      local func = functionValue(script, handler)
      if func then
        local count = #func.args
        if count < spec.minArgs or count > spec.maxArgs then
          table.insert(out, finding(
            'handler.signature', 'handlers', 'error', 'proven', script, handler.line,
            `'{handler.name}' has {count} parameter(s), expected {spec.minArgs}..{spec.maxArgs}`,
            nil
          ))
        end
      else
        table.insert(out, finding(
          'handler.indirect', 'handlers', 'note', 'inferred', script, handler.line,
          `'{handler.name}' resolves through an expression the workbench cannot prove is a function`,
          'The handler still participates in context/event graphs, but signature checks are skipped.'
        ))
      end
    end
  end
end

local function findReturns(block, out)
  for _, stat in block.body do
    if stat.kind == 'StatReturn' then
      table.insert(out, stat)
    elseif stat.kind == 'StatIf' then
      findReturns(stat.thenbody, out)
      if stat.elsebody and stat.elsebody.kind == 'StatBlock' then findReturns(stat.elsebody, out) end
    elseif stat.kind == 'StatWhile' or stat.kind == 'StatRepeat' or stat.kind == 'StatFor' or stat.kind == 'StatForIn' then
      findReturns(stat.body, out)
    end
  end
end

local function saveHasVersion(script, handler): boolean
  local func = functionValue(script, handler)
  if not func then return false end
  local returns = {}
  findReturns(func.body, returns)
  for _, stat in returns do
    for _, expr in stat.list do
      local value = analysis.resolve(script.source, expr)
      if value.kind == 'ExprTable' and analysis.resolvedTableField(script.source, value, 'version') then return true end
    end
  end
  return false
end

local RiskyTopLevelModules: { [string]: boolean } = {
  ['openmw.world'] = true,
  ['openmw.nearby'] = true,
  ['openmw.self'] = true,
  ['openmw.ui'] = true,
  ['openmw.input'] = true,
  ['openmw.camera'] = true,
  ['openmw.menu'] = true,
  ['openmw.postprocessing'] = true,
  ['openmw.animation'] = true,
  ['openmw.ambient'] = true,
  ['openmw.debug'] = true,
}

local MutatingTopLevelModules: { [string]: boolean } = {
  ['openmw.core'] = true,
  ['openmw.interfaces'] = true,
}

local function riskyTopLevel(call): boolean
  if not call.module then return false end
  if RiskyTopLevelModules[call.module] then return true end
  if not MutatingTopLevelModules[call.module] or not call.member then return false end
  local leaf = string.match(call.member, '([^.]+)$') or call.member
  local lower = string.lower(leaf)
  return string.find(lower, '^create') ~= nil
    or string.find(lower, '^spawn') ~= nil
    or string.find(lower, '^move') ~= nil
    or string.find(lower, '^teleport') ~= nil
    or string.find(lower, '^activate') ~= nil
    or string.find(lower, '^play') ~= nil
    or string.find(lower, '^stop') ~= nil
    or string.find(lower, '^show') ~= nil
    or string.find(lower, '^set') ~= nil
    or string.find(lower, '^add') ~= nil
    or string.find(lower, '^remove') ~= nil
    or string.find(lower, '^send') ~= nil
    or string.find(lower, '^register') ~= nil
    or string.find(lower, '^update') ~= nil
    or string.find(lower, '^clear') ~= nil
    or string.find(lower, '^enable') ~= nil
    or string.find(lower, '^disable') ~= nil
    or string.find(lower, '^request') ~= nil
    or string.find(lower, '^load') ~= nil
    or string.find(lower, '^save') ~= nil
end

local function checkLifecycle(project, enabled, out)
  if not hasCategory(enabled, 'lifecycle') then return end

  for _, script in project.scripts do
    local handlers = handlerMap(script)
    if handlers.onSave and not handlers.onLoad then
      table.insert(out, finding(
        'lifecycle.save-pair', 'lifecycle', 'error', 'proven', script, handlers.onSave.line,
        'onSave exists without onLoad',
        'Persistent script state needs an explicit load path so fresh games and existing saves do not share accidental initialization behavior.'
      ))
    end

    if handlers.onSave and not saveHasVersion(script, handlers.onSave) then
      table.insert(out, finding(
        'lifecycle.unversioned-save', 'lifecycle', 'warning', 'inferred', script, handlers.onSave.line,
        'saved state has no statically visible version field',
        'Versioning makes migrations and old-save compatibility explicit. Dynamic/opaque returns may be a false positive.'
      ))
    end

    for _, call in script.source.calls do
      if call.functionDepth ~= 0 or not riskyTopLevel(call) then continue end
      table.insert(out, finding(
        'lifecycle.top-level-openmw', 'lifecycle', 'warning', 'heuristic', script, call.line,
        `top-level OpenMW call '{call.target or call.module}'`,
        'Require-time engine work can run before cross-context dependencies or existing-save state are ready; prefer lifecycle handlers unless the API contract explicitly permits eager use.'
      ))
    end
  end
end

local function inside(handler, line: number): boolean
  local func = handler.value
  return func and func.kind == 'ExprFunction' and line >= func.line and line <= func.endLine
end

local function hotHandlers(script)
  local found = {}
  for _, handler in script.engineHandlers do
    local spec = knowledge.engineHandlers[handler.name]
    if spec and spec.hot and handler.value and handler.value.kind == 'ExprFunction' then table.insert(found, handler) end
  end
  return found
end

local function checkStorage(project, enabled, out)
  if not hasCategory(enabled, 'storage') then return end

  for _, script in project.scripts do
    local hot = hotHandlers(script)
    for _, op in script.storageOperations do
      if op.access ~= 'write' then continue end

      if op.functionDepth == 0 then
        table.insert(out, finding(
          'storage.top-level-write', 'storage', 'warning', 'proven', script, op.line,
          `persistent storage write at module top level ({op.binding}:{op.operation})`,
          'Top-level writes run on script load and can overwrite existing-save state or create ordering dependencies.'
        ))
      end

      for _, handler in hot do
        if inside(handler, op.line) then
          table.insert(out, finding(
            'storage.hot-write', 'storage', 'warning', 'proven', script, op.line,
            `persistent storage write inside hot handler '{handler.name}'`,
            'Accumulate dirty state and persist at an event-driven or bounded cadence instead of paying serialization/notification cost every frame.'
          ))
        end
      end
    end
  end
end

local function checkEvents(project, enabled, out)
  if not hasCategory(enabled, 'events') then return end
  local sent, handled = {}, {}

  for _, script in project.scripts do
    for _, event in script.sentEvents do
      sent[event.name] = sent[event.name] or {}
      table.insert(sent[event.name], { script = script, event = event })
    end

    for _, handler in script.eventHandlers do
      handled[handler.name] = handled[handler.name] or {}
      table.insert(handled[handler.name], { script = script, handler = handler })
    end

    for _, event in script.dynamicEvents do
      table.insert(out, finding(
        'event.dynamic-name', 'events', 'note', 'proven', script, event.line,
        'dynamic event name escapes whole-project matching',
        'Literal event names let the workbench prove sender/receiver relationships and detect dead contracts.'
      ))
    end
  end

  for name, sends in sent do
    if handled[name] then continue end

    for _, item in sends do
      table.insert(out, finding(
        'event.void', 'events', 'warning', 'proven', item.script, item.event.line,
        `event '{name}' is sent but no scanned script handles it`,
        'This can be intentional when another mod provides the handler; otherwise it is a dead event edge.'
      ))
    end
  end

  for name, handlers in handled do
    if sent[name] then continue end

    for _, item in handlers do
      table.insert(out, finding(
        'event.never-sent', 'events', 'note', 'inferred', item.script, item.handler.line,
        `event handler '{name}' has no scanned sender`,
        'External mods or engine glue may send it; within the scanned project the edge is currently orphaned.'
      ))
    end
  end
end

local function checkInterfaces(project, enabled, out)
  if not hasCategory(enabled, 'interfaces') then return end
  local providers = {}
  for _, script in project.scripts do
    local interface = script.interface
    if not interface then continue end

    if not string.find(interface.name, '^[%w_]+$') then
      table.insert(out, finding(
        'interface.name', 'interfaces', 'warning', 'proven', script, interface.line,
        `interface name '{interface.name}' contains unusual characters`, nil
      ))
    end
    providers[interface.name] = providers[interface.name] or {}
    table.insert(providers[interface.name], script)
  end

  for name, scripts in providers do
    if #scripts < 2 then continue end

    for _, script in scripts do
      table.insert(out, finding(
        'interface.collision', 'interfaces', 'error', 'proven', script, script.interface.line,
        `interface '{name}' is provided by multiple scanned scripts`,
        table.concat((function()
          local paths = {}
          for _, other in scripts do table.insert(paths, other.path) end
          table.sort(paths)
          return paths
        end)(), ', ')
      ))
    end
  end
end

local function checkUi(project, enabled, out)
  if not hasCategory(enabled, 'ui') then return end

  for _, script in project.scripts do
    for _, create in script.uiCreates do
      if create.layout and create.layout.kind == 'ExprTable' and not create.layer then
        table.insert(out, finding(
          'ui.layer', 'ui', 'warning', 'proven', script, create.line,
          'ui.create layout has no statically visible layer',
          'Attach UI to an explicit OpenMW layer so ordering and lifecycle are deliberate.'
        ))
      end
    end
  end
end

local function checkPerformance(project, enabled, out)
  if not hasCategory(enabled, 'performance') then return end

  for _, script in project.scripts do
    local hot = hotHandlers(script)
    for _, handler in hot do
      local allocationLines: { [number]: number } = {}
      for _, tableFact in script.source.tables do
        if inside(handler, tableFact.line) then
          allocationLines[tableFact.line] = (allocationLines[tableFact.line] or 0) + 1
        end
      end

      for line, count in allocationLines do
        table.insert(out, finding(
          'performance.allocation', 'performance', 'warning', 'heuristic', script, line,
          `{count} table allocation(s) occur inside hot handler '{handler.name}'`,
          'This is structural evidence, not a measured cost. Reuse or hoist only when profiling says the path matters.'
        ))
      end

      for _, func in script.source.functions do
        if func.node == handler.value then continue end

        if inside(handler, func.line) then
          table.insert(out, finding(
            'performance.closure', 'performance', 'warning', 'heuristic', script, func.line,
            `closure construction occurs inside hot handler '{handler.name}'`,
            'Hoist stable callbacks when the closure is recreated every frame and profiling confirms allocation pressure.'
          ))
        end
      end
    end
  end
end

local function compare(left: Finding, right: Finding): boolean
  if left.path ~= right.path then return left.path < right.path end
  if left.line ~= right.line then return left.line < right.line end
  if left.column ~= right.column then return left.column < right.column end
  return left.code < right.code
end

local function review(project, options)
  local given = options or {}
  local enabled = enabledCategories(given.profile)
  local findings: { Finding } = {}
  checkContexts(project, enabled, findings)
  checkHandlers(project, enabled, findings)
  checkLifecycle(project, enabled, findings)
  checkStorage(project, enabled, findings)
  checkEvents(project, enabled, findings)
  checkInterfaces(project, enabled, findings)
  checkUi(project, enabled, findings)
  checkPerformance(project, enabled, findings)
  table.sort(findings, compare)

  local errors, warnings, notes = 0, 0, 0
  for _, item in findings do
    if item.severity == 'error' then errors += 1
    elseif item.severity == 'warning' then warnings += 1
    else notes += 1 end
  end

  return {
    profile = given.profile or 'default',
    findings = findings,
    summary = {
      errors = errors,
      warnings = warnings,
      notes = notes,
      scripts = #project.scripts,
      manifests = #project.manifests,
      ok = errors == 0,
    },
  }
end

local function format(item: Finding): string
  local prefix = `{item.path}:{item.line}:{item.column}: {item.severity}[{item.code}]`
  local evidence = string.upper(item.confidence)
  return `{prefix}: {item.message} ({evidence})`
end

return table.freeze {
  review = review,
  format = format,
}
