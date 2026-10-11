--!strict
--!native
local analysis = require '@jess/analysis'
local knowledge = require '@openmw/workbench/knowledge'
local content = require '@openmw/workbench/content'

type Source = analysis.Source
type Workspace = analysis.Workspace
type Expr = dream_luau_Expr
type ContextSet = { [string]: boolean }

local ValidContexts: { [string]: boolean } = {
  global = true,
  ['local'] = true,
  player = true,
  menu = true,
  load = true,
  runtime = true,
  all = true,
  none = true,
}

local ManifestContexts: { [string]: string } = {
  GLOBAL = 'global',
  PLAYER = 'player',
  MENU = 'menu',
  CUSTOM = 'local',
  LOCAL = 'local',
  LOAD = 'load',
}

-- OpenMW's text configuration accepts record type tags as auto-attached local scripts.
-- Keep this list in lockstep with components/lua/configuration.cpp::typeTagsByName.
local ManifestLocalTypeTags: { [string]: boolean } = {
  ACTIVATOR = true,
  ARMOR = true,
  BOOK = true,
  CLOTHING = true,
  CONTAINER = true,
  CREATURE = true,
  DOOR = true,
  INGREDIENT = true,
  LIGHT = true,
  MISC_ITEM = true,
  NPC = true,
  POTION = true,
  WEAPON = true,
  APPARATUS = true,
  LOCKPICK = true,
  PROBE = true,
  REPAIR = true,
}

local function setFrom(list: { string }): ContextSet
  local result = {}
  for _, value in list do result[value] = true end
  return result
end

local function setClone(values: ContextSet): ContextSet
  local result = {}
  for value in values do result[value] = true end
  return result
end

local function setList(values: ContextSet): { string }
  local result = {}
  for value in values do table.insert(result, value) end
  table.sort(result)
  return result
end

local function setUnion(target: ContextSet, values: ContextSet): boolean
  local changed = false
  for value in values do
    if target[value] then continue end
    target[value] = true
    changed = true
  end
  return changed
end

local function setIntersection(left: ContextSet, right: ContextSet): ContextSet
  local result = {}
  for value in left do
    if right[value] then result[value] = true end
  end
  return result
end

local function setContains(values: ContextSet, value: string): boolean
  return values[value] == true
end

local function setEmpty(values: ContextSet): boolean
  return next(values) == nil
end

local function parseContextExpression(text: string): (ContextSet, { string }, boolean)
  local result, invalid = {}, {}
  local none = false

  for raw in string.gmatch(text, '[^|]+') do
    local value = string.lower(string.match(raw, '^%s*(.-)%s*$') or '')
    if value == '' then continue end

    if not ValidContexts[value] then
      table.insert(invalid, value)
    elseif value == 'all' then
      for _, context in knowledge.allContexts do result[context] = true end
    elseif value == 'runtime' then
      for _, context in knowledge.runtimeContexts do result[context] = true end
    elseif value == 'none' then
      none = true
    else
      result[value] = true
    end
  end

  table.sort(invalid)
  return result, invalid, none
end

local function contextAnnotations(text: string)
  local fileContexts: ContextSet? = nil
  local fileNone = false
  local invalid = {}
  local nextOverrides: { [number]: ContextSet } = {}
  local nextNone: { [number]: boolean } = {}
  local ranges, stack = {}, {}
  local lineNumber = 0

  for line in string.gmatch(text .. '\n', '([^\n]*)\n') do
    lineNumber += 1
    if not string.find(line, '@omw-context', 1, true) then continue end
    local default = string.match(line, '^%s*%-%-%-@omw%-context%s+(.+)%s*$')
    local nextValue = string.match(line, '^%s*%-%-%-@omw%-context%-next%s+(.+)%s*$')
    local beginValue = string.match(line, '^%s*%-%-%-@omw%-context%-begin%s+(.+)%s*$')
    local isEnd = string.find(line, '^%s*%-%-%-@omw%-context%-end[%s%w_|]*$') ~= nil

    if default then
      local parsed, bad, none = parseContextExpression(default)
      fileContexts, fileNone = parsed, none
      for _, value in bad do table.insert(invalid, { line = lineNumber, value = value }) end
    elseif nextValue then
      local parsed, bad, none = parseContextExpression(nextValue)
      nextOverrides[lineNumber], nextNone[lineNumber] = parsed, none
      for _, value in bad do table.insert(invalid, { line = lineNumber, value = value }) end
    elseif beginValue then
      local parsed, bad, none = parseContextExpression(beginValue)
      table.insert(stack, { contexts = parsed, none = none, first = lineNumber + 1 })
      for _, value in bad do table.insert(invalid, { line = lineNumber, value = value }) end
    elseif isEnd and #stack > 0 then
      local active = table.remove(stack)
      table.insert(ranges, { first = active.first, last = lineNumber - 1, contexts = active.contexts, none = active.none })
    end
  end

  while #stack > 0 do
    local active = table.remove(stack)
    table.insert(ranges, { first = active.first, last = lineNumber, contexts = active.contexts, none = active.none })
  end

  return {
    default = fileContexts,
    defaultNone = fileNone,
    invalid = invalid,
    nextOverrides = nextOverrides,
    nextNone = nextNone,
    ranges = ranges,
  }
end

local function contextAnnotationsSource(source: Source)
  local fileContexts: ContextSet? = nil
  local fileNone = false
  local invalid = {}
  local nextOverrides: { [number]: ContextSet } = {}
  local nextNone: { [number]: boolean } = {}
  local ranges, stack = {}, {}
  local lastLine = #source.lineStarts

  for _, comment in source.comments do
    if comment.kind ~= 'line' then continue end
    local lineNumber = comment.line
    local lineStart = source.lineStarts[lineNumber]
    if not lineStart then continue end
    local first = lineStart + comment.column - 1
    local last = lineStart + comment.endColumn - 1
    local line = string.sub(source.source, first, last)
    if not string.find(line, '@omw-context', 1, true) then continue end
    local default = string.match(line, '^%s*%-%-%-@omw%-context%s+(.+)%s*$')
    local nextValue = string.match(line, '^%s*%-%-%-@omw%-context%-next%s+(.+)%s*$')
    local beginValue = string.match(line, '^%s*%-%-%-@omw%-context%-begin%s+(.+)%s*$')
    local isEnd = string.find(line, '^%s*%-%-%-@omw%-context%-end[%s%w_|]*$') ~= nil

    if default then
      local parsed, bad, none = parseContextExpression(default)
      fileContexts, fileNone = parsed, none
      for _, value in bad do table.insert(invalid, { line = lineNumber, value = value }) end
    elseif nextValue then
      local parsed, bad, none = parseContextExpression(nextValue)
      nextOverrides[lineNumber], nextNone[lineNumber] = parsed, none
      for _, value in bad do table.insert(invalid, { line = lineNumber, value = value }) end
    elseif beginValue then
      local parsed, bad, none = parseContextExpression(beginValue)
      table.insert(stack, { contexts = parsed, none = none, first = lineNumber + 1 })
      for _, value in bad do table.insert(invalid, { line = lineNumber, value = value }) end
    elseif isEnd and #stack > 0 then
      local active = table.remove(stack)
      table.insert(ranges, { first = active.first, last = lineNumber - 1, contexts = active.contexts, none = active.none })
    end
  end

  while #stack > 0 do
    local active = table.remove(stack)
    table.insert(ranges, { first = active.first, last = lastLine, contexts = active.contexts, none = active.none })
  end

  return {
    default = fileContexts,
    defaultNone = fileNone,
    invalid = invalid,
    nextOverrides = nextOverrides,
    nextNone = nextNone,
    ranges = ranges,
  }
end

local function contextInfoForLine(annotations, line: number)
  local best = nil
  for _, range in annotations.ranges do
    if line >= range.first and line <= range.last then
      if not best or range.first >= best.first then best = range end
    end
  end

  if best then return best.contexts, best.none end

  local bestLine, contexts, none = 0, nil, false
  for annotationLine, value in annotations.nextOverrides do
    if annotationLine < line and annotationLine > bestLine and line - annotationLine <= 3 then
      bestLine, contexts, none = annotationLine, value, annotations.nextNone[annotationLine] == true
    end
  end

  if contexts then return contexts, none end
  return annotations.default, annotations.defaultNone == true
end

local function contextsForLine(annotations, line: number): ContextSet?
  local contexts, none = contextInfoForLine(annotations, line)
  if none then return nil end
  return contexts
end

local function normalize(path: string): string
  return string.lower(analysis.normalizePath(path))
end

local function openmwModuleIndex(workspace: Workspace)
  local index = {}
  for _, path in workspace.files do
    local lower = normalize(path)
    local start = 1
    while true do
      local suffix = string.sub(lower, start)
      local current = index[suffix]
      if current == nil then index[suffix] = path
      elseif current ~= path then index[suffix] = false end
      local slash = string.find(lower, '/', start, true)
      if not slash then break end
      start = slash + 1
    end
  end
  return index
end

local function openmwLocalModuleTarget(index, moduleName: string): string?
  local candidate = string.lower(string.gsub(moduleName, '%.', '/'))
  local suffixes = { `{candidate}.lua`, `{candidate}.luau`, `{candidate}/init.lua`, `{candidate}/init.luau` }
  local match: string? = nil
  for _, suffix in suffixes do
    local value = index[suffix]
    if value == false then return nil end

    if type(value) == 'string' then
      if match and match ~= value then return nil end
      match = value
    end
  end
  return match
end

local function collectManifests(roots: { string }): { string }
  local found = {}

  local function visit(path: string)
    if jess.fs.isDir(path) then
      for _, name in jess.fs.list(path) do
        if string.sub(name, 1, 1) == '.' or name == 'target' or name == 'node_modules' then continue end
        visit(jess.fs.join(path, name))
      end
      return
    end

    local lower = string.lower(path)
    if jess.fs.isFile(path) and (string.find(lower, '%.omwscripts$') or string.find(lower, '%.omwscripts%.in$')) then
      table.insert(found, analysis.normalizePath(path))
    end
  end

  for _, root in roots do visit(root) end
  table.sort(found)
  return found
end

local function collectContentConfigs(roots: { string }): { string }
  local found = {}

  local function visit(path: string)
    if jess.fs.isDir(path) then
      for _, name in jess.fs.list(path) do
        if string.sub(name, 1, 1) == '.' or name == 'target' or name == 'node_modules' then continue end
        visit(jess.fs.join(path, name))
      end
      return
    end

    local lower = string.lower(path)
    if jess.fs.isFile(path) and (string.find(lower, '%.omwaddon$') or string.find(lower, '%.omwgame$')) then
      table.insert(found, analysis.normalizePath(path))
    end
  end

  for _, root in roots do visit(root) end
  table.sort(found)
  return found
end

local function collectConfigs(roots: { string }): ({ string }, { string })
  local manifests, contentConfigs = {}, {}

  local function visit(path: string)
    if jess.fs.isDir(path) then
      for _, name in jess.fs.list(path) do
        if string.sub(name, 1, 1) == '.' or name == 'target' or name == 'node_modules' then continue end
        visit(jess.fs.join(path, name))
      end
      return
    end

    if not jess.fs.isFile(path) then return end
    local lower = string.lower(path)
    if string.find(lower, '%.omwscripts$') or string.find(lower, '%.omwscripts%.in$') then
      table.insert(manifests, analysis.normalizePath(path))
    elseif string.find(lower, '%.omwaddon$') or string.find(lower, '%.omwgame$') then
      table.insert(contentConfigs, analysis.normalizePath(path))
    end
  end

  for _, root in roots do visit(root) end
  table.sort(manifests)
  table.sort(contentConfigs)
  return manifests, contentConfigs
end

local function parseManifest(path: string, text: string)
  local declarations = {}
  local lineNumber = 0

  for line in string.gmatch(text .. '\n', '([^\n]*)\n') do
    lineNumber += 1
    local stripped = string.match(line, '^%s*(.-)%s*$') or ''
    if stripped == '' or string.sub(stripped, 1, 1) == '#' then continue end

    local tagText, script = string.match(stripped, '^([^:]+)%s*:%s*(.-)%s*$')
    if not tagText or not script or string.lower(string.sub(script, -4)) ~= '.lua' then continue end

    local contexts: { [string]: boolean } = {}
    for rawTag in string.gmatch(tagText, '[^,%s]+') do
      local tag = string.upper(rawTag)
      local context = ManifestContexts[tag]
      if context then
        contexts[context] = true
      elseif ManifestLocalTypeTags[tag] then
        contexts['local'] = true
      end
    end

    for context in contexts do
      table.insert(declarations, {
        manifest = path,
        line = lineNumber,
        path = analysis.normalizePath(script),
        normalizedPath = normalize(script),
        context = context,
        tags = tagText,
      })
    end
  end

  return declarations
end

local function parseContentConfig(path: string)
  local declarations = {}
  -- The tes3 package rejects malformed/non-plugin content paths; keep scanning source roots when one cannot be decoded.
  local ok, scripts = pcall(content.scriptConfig, path)
  if not ok or type(scripts) ~= 'table' then return declarations end

  for index, script in scripts do
    if type(script) ~= 'table' or type(script.path) ~= 'string' then continue end
    local contexts: ContextSet = {}

    if type(script.flags) == 'string' then
      for rawTag in string.gmatch(script.flags, '[%u_]+') do
        local context = ManifestContexts[rawTag]
        if context then contexts[context] = true end
      end
    end

    -- Type, record, and reference attachments are local-script configuration.
    -- LUAL's display representation uses ESM record tags (NPC_, CREA, ...), so
    -- the presence of one of these lists is the semantic fact we need here.
    if type(script.types) == 'table' and next(script.types) ~= nil then contexts['local'] = true end
    if type(script.records) == 'table' and next(script.records) ~= nil then contexts['local'] = true end
    if type(script.refs) == 'table' and next(script.refs) ~= nil then contexts['local'] = true end

    for context in contexts do
      table.insert(declarations, {
        manifest = path,
        line = index,
        path = analysis.normalizePath(script.path),
        normalizedPath = normalize(script.path),
        context = context,
        tags = script.flags or 'LUAL local attachment',
        sourceKind = 'content',
      })
    end
  end

  return declarations
end

local function sourceByScriptPath(workspace: Workspace, scriptPath: string): Source?
  local wanted = normalize(scriptPath)
  for path, source in workspace.byPath do
    local candidate = normalize(path)
    if candidate == wanted or string.sub(candidate, -#wanted) == wanted then return source end
  end
  return nil
end

local function openmwLocalRequireEdges(workspace: Workspace)
  local edges = {}
  local seen, seenRequire = {}, {}
  local moduleIndex = openmwModuleIndex(workspace)

  local function add(from: string, to: string, moduleName: string, line: number)
    local key = `{from}:{line}:{moduleName}:{to}`
    if seen[key] then return end
    seen[key] = true
    seenRequire[`{from}:{line}:{moduleName}`] = true
    table.insert(edges, { from = from, to = to, module = moduleName, line = line })
  end

  for _, edge in workspace.requireEdges do add(edge.from, edge.to, edge.module, edge.line) end

  for _, source in workspace.sources do
    local from = source.path :: string
    for _, required in source.requires do
      if string.sub(required.module, 1, 1) == '@' or string.find(required.module, '^openmw%.') then continue end
      if seenRequire[`{from}:{required.line}:{required.module}`] then continue end

      local target = openmwLocalModuleTarget(moduleIndex, required.module)
      if target then add(from, target, required.module, required.line) end
    end
  end

  table.sort(edges, function(left, right)
    if left.from ~= right.from then return left.from < right.from end
    if left.to ~= right.to then return left.to < right.to end
    return left.line < right.line
  end)
  return edges
end

local function resolved(source: Source, expr: Expr?): Expr?
  if not expr then return nil end
  return analysis.resolve(source, expr)
end

local function recordFields(source: Source, expr: Expr?): { { name: string, value: Expr, line: number } }
  local value = resolved(source, expr)
  if not value or value.kind ~= 'ExprTable' then return {} end
  local fields = {}

  for _, item in value.items do
    if item.itemKind ~= 'record' or not item.key or item.key.kind ~= 'ExprConstantString' then continue end
    table.insert(fields, { name = item.key.value, value = item.value, line = item.line })
  end

  return fields
end

local function returnRootName(source: Source): string?
  local expr = source.moduleReturn
  if expr and expr.kind == 'ExprLocal' then return expr['local'].name end
  return nil
end

local function handlerTable(source: Source, tableName: string)
  local handlers = {}
  local returned = source.moduleReturn
  if not returned then return handlers end

  local field = analysis.resolvedTableField(source, returned, tableName)
  for _, entry in recordFields(source, field) do
    table.insert(handlers, {
      name = entry.name,
      value = resolved(source, entry.value) or entry.value,
      line = entry.line,
      functionDepth = 0,
      conditionalDepth = 0,
      source = source,
    })
  end

  local rootName = returnRootName(source)
  if rootName then
    local prefix = `{rootName}.{tableName}.`
    for _, assignment in source.assignments do
      local target = assignment.target
      if not target or string.sub(target, 1, #prefix) ~= prefix then continue end
      local name = string.sub(target, #prefix + 1)
      if string.find(name, '%.', 1, true) then continue end

      table.insert(handlers, {
        name = name,
        value = if assignment.value then resolved(source, assignment.value) or assignment.value else nil,
        line = assignment.line,
        functionDepth = assignment.functionDepth,
        conditionalDepth = assignment.conditionalDepth,
        source = source,
      })
    end
  end

  table.sort(handlers, function(left, right)
    if left.name ~= right.name then return left.name < right.name end
    return left.line < right.line
  end)
  return handlers
end

local function literalString(source: Source, expr: Expr?): string?
  local value = resolved(source, expr)
  if value and value.kind == 'ExprConstantString' then return value.value end
  return nil
end

local function interfaceInfo(source: Source)
  if not source.moduleReturn then return nil end
  local nameExpr = analysis.resolvedTableField(source, source.moduleReturn, 'interfaceName')
  local name = literalString(source, nameExpr)
  if not name then return nil end
  return { name = name, line = nameExpr and nameExpr.line or source.moduleReturn.line }
end

local function rootLocal(expr: Expr): dream_luau_Local?
  local current = expr
  while current.kind == 'ExprIndexName' or current.kind == 'ExprIndexExpr' do current = current.expr end
  if current.kind == 'ExprLocal' then return current['local'] end
  return nil
end

local function storageFacts(source: Source)
  local sections, bindings, operations = {}, {}, {}

  for localValue, value in source.localValues do
    if value.kind ~= 'ExprCall' then continue end
    local target, module, member = analysis.qualifiedPath(value.func, source.origins)
    if module ~= 'openmw.storage' or not member then continue end
    local scope = string.match(member, '^(global)Section$') or string.match(member, '^(player)Section$') or string.match(member, '^(local)Section$')
    if not scope then continue end
    local name = literalString(source, value.args[1])
    local fact = { scope = scope, section = name, line = value.line, binding = localValue.name, call = value }
    table.insert(sections, fact)
    bindings[localValue] = fact
  end

  for _, call in source.calls do
    local func = call.expr.func
    if func.kind ~= 'ExprIndexName' then continue end
    local localValue = rootLocal(func.expr)
    local section = localValue and bindings[localValue]
    if not section then continue end
    local op = func.index
    local access = if op == 'set' or op == 'remove' or op == 'reset' then 'write'
      elseif op == 'get' or op == 'asTable' then 'read'
      elseif op == 'subscribe' then 'subscribe'
      else 'other'
    table.insert(operations, {
      scope = section.scope,
      section = section.section,
      binding = section.binding,
      operation = op,
      access = access,
      line = call.line,
      functionDepth = call.functionDepth,
      conditionalDepth = call.conditionalDepth,
      call = call,
    })
  end

  return sections, operations
end

local function eventFacts(source: Source)
  local sent, dynamic = {}, {}
  for _, call in source.calls do
    local target = call.target or ''
    local isGlobal = target == 'openmw.core.sendGlobalEvent'
    local isObject = string.sub(target, -10) == '.sendEvent'
    if not isGlobal and not isObject then continue end
    local name = literalString(source, call.expr.args[1])
    local item = {
      name = name,
      line = call.line,
      kind = if isGlobal then 'global' else 'object',
      call = call,
    }

    if name then table.insert(sent, item) else table.insert(dynamic, item) end
  end
  return sent, dynamic
end

local function uiFacts(source: Source)
  local creates = {}
  for _, call in source.calls do
    if call.module ~= 'openmw.ui' or call.member ~= 'create' then continue end
    local layout = resolved(source, call.expr.args[1])
    local layer = layout and analysis.resolvedTableField(source, layout, 'layer')
    table.insert(creates, {
      line = call.line,
      call = call,
      layout = layout,
      layer = literalString(source, layer),
    })
  end
  return creates
end

local function contextsOverlap(left: ContextSet, right: ContextSet): boolean
  for value in left do if right[value] then return true end end
  return false
end

local function isIdentifierByte(byte: number?): boolean
  if not byte then return false end
  return byte == 95 or (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)
end

local function longBracketEnd(text: string, first: number): number?
  if string.byte(text, first) ~= 91 then return nil end
  local cursor = first + 1
  while string.byte(text, cursor) == 61 do cursor += 1 end
  if string.byte(text, cursor) ~= 91 then return nil end
  local equals = cursor - first - 1
  local closing = `]{string.rep('=', equals)}]`
  local close = string.find(text, closing, cursor + 1, true)
  if not close then return #text + 1 end
  return close + #closing
end

local function normalizeOpenmwLua(text: string, _path: string): string
  local edits = {}
  local size = #text

  if size >= 3 and string.byte(text, 1) == 239 and string.byte(text, 2) == 187 and string.byte(text, 3) == 191 then
    table.insert(edits, { first = 1, last = 3 })
  end

  if not string.find(text, 'goto', 1, true) and not string.find(text, '::', 1, true) and #edits == 0 then return text end

  local cursor = 1
  while cursor <= size do
    local byte = string.byte(text, cursor)

    if byte == 45 and string.byte(text, cursor + 1) == 45 then
      local longEnd = longBracketEnd(text, cursor + 2)
      if longEnd then cursor = longEnd
      else
        local newline = string.find(text, '\n', cursor + 2, true)
        cursor = if newline then newline + 1 else size + 1
      end
      continue
    end

    if byte == 34 or byte == 39 then
      local quote = byte
      cursor += 1
      while cursor <= size do
        local current = string.byte(text, cursor)
        if current == 92 then cursor += 2
        elseif current == quote then cursor += 1 break
        else cursor += 1 end
      end
      continue
    end

    if byte == 91 then
      local longEnd = longBracketEnd(text, cursor)
      if longEnd then cursor = longEnd continue end
    end

    if byte == 58 and string.byte(text, cursor + 1) == 58 then
      local name = cursor + 2
      while true do
        local space = string.byte(text, name)
        if space == 32 or space == 9 or space == 11 or space == 12 then name += 1 else break end
      end
      local firstName = string.byte(text, name)
      if isIdentifierByte(firstName) and not ((firstName or 0) >= 48 and (firstName or 0) <= 57) then
        local finish = name + 1
        while isIdentifierByte(string.byte(text, finish)) do finish += 1 end

        while true do
          local space = string.byte(text, finish)
          if space == 32 or space == 9 or space == 11 or space == 12 then finish += 1 else break end
        end

        if string.byte(text, finish) == 58 and string.byte(text, finish + 1) == 58 then
          table.insert(edits, { first = cursor, last = finish + 1 })
          cursor = finish + 2
          continue
        end
      end
    end

    if byte == 103 and string.sub(text, cursor, cursor + 3) == 'goto' then
      local before = string.byte(text, cursor - 1)
      local after = string.byte(text, cursor + 4)
      if not isIdentifierByte(before) and (after == 32 or after == 9 or after == 11 or after == 12) then
        local name = cursor + 4
        while true do
          local space = string.byte(text, name)
          if space == 32 or space == 9 or space == 11 or space == 12 then name += 1 else break end
        end
        local firstName = string.byte(text, name)
        if isIdentifierByte(firstName) and not ((firstName or 0) >= 48 and (firstName or 0) <= 57) then
          local finish = name + 1
          while isIdentifierByte(string.byte(text, finish)) do finish += 1 end
          table.insert(edits, { first = cursor, last = finish - 1 })
          cursor = finish
          continue
        end
      end
    end

    cursor += 1
  end

  if #edits == 0 then return text end
  table.sort(edits, function(left, right) return left.first < right.first end)
  local out = {}
  local first = 1
  for _, edit in edits do
    if edit.first < first then continue end
    if edit.first > first then table.insert(out, string.sub(text, first, edit.first - 1)) end
    table.insert(out, string.rep(' ', edit.last - edit.first + 1))
    first = edit.last + 1
  end

  if first <= size then table.insert(out, string.sub(text, first)) end
  return table.concat(out)
end

local function build(roots: { string })
  local workspace = analysis.workspace(roots, { transform = normalizeOpenmwLua })
  local requireEdges = openmwLocalRequireEdges(workspace)
  local manifests, contentConfigs = collectConfigs(roots)
  local declarations = {}
  for _, path in manifests do
    local text = jess.fs.read(path) or ''
    for _, declaration in parseManifest(path, text) do table.insert(declarations, declaration) end
  end

  for _, path in contentConfigs do
    for _, declaration in parseContentConfig(path) do table.insert(declarations, declaration) end
  end

  local annotationsByPath = {}
  local declaredByPath: { [string]: ContextSet } = {}
  local manifestByPath = {}
  for _, source in workspace.sources do
    annotationsByPath[source.path] = contextAnnotationsSource(source)
  end

  for _, declaration in declarations do
    local source = sourceByScriptPath(workspace, declaration.path)
    if not source or not source.path then continue end

    declaredByPath[source.path] = declaredByPath[source.path] or {}
    declaredByPath[source.path][declaration.context] = true
    manifestByPath[source.path] = manifestByPath[source.path] or {}
    table.insert(manifestByPath[source.path], declaration)
  end

  local effective: { [string]: ContextSet } = {}
  for _, source in workspace.sources do
    local path = source.path :: string
    effective[path] = {}
    local declared = declaredByPath[path]
    if declared then
      setUnion(effective[path], declared)
    elseif annotationsByPath[path].default and not annotationsByPath[path].defaultNone then
      setUnion(effective[path], annotationsByPath[path].default)
    end
  end

  local changed = true
  while changed do
    changed = false
    for _, edge in requireEdges do
      local caller = effective[edge.from]
      local target = effective[edge.to]
      if not caller or not target or setEmpty(caller) then continue end
      local targetAnnotations = annotationsByPath[edge.to]
      local allowed = targetAnnotations and targetAnnotations.default
      local propagated = if targetAnnotations and targetAnnotations.defaultNone then caller elseif allowed then setIntersection(caller, allowed) else caller
      if setUnion(target, propagated) then changed = true end
    end
  end

  local scripts, byPath = {}, {}
  for _, source in workspace.sources do
    local path = source.path :: string
    local annotations = annotationsByPath[path]
    local engineHandlers = handlerTable(source, 'engineHandlers')
    local eventHandlers = handlerTable(source, 'eventHandlers')
    local sentEvents, dynamicEvents = eventFacts(source)
    local storageSections, storageOperations = storageFacts(source)
    local script = {
      path = path,
      source = source,
      annotations = annotations,
      declaredContexts = declaredByPath[path] or {},
      contexts = effective[path],
      manifests = manifestByPath[path] or {},
      engineHandlers = engineHandlers,
      eventHandlers = eventHandlers,
      sentEvents = sentEvents,
      dynamicEvents = dynamicEvents,
      interface = interfaceInfo(source),
      storageSections = storageSections,
      storageOperations = storageOperations,
      uiCreates = uiFacts(source),
      openmwRequires = {},
    }

    for _, required in source.requires do
      if string.find(required.module, '^openmw%.') then
        table.insert(script.openmwRequires, {
          module = required.module,
          line = required.line,
          contexts = (function()
            local contexts, none = contextInfoForLine(annotations, required.line)
            if none then return effective[path] end
            return contexts or effective[path]
          end)(),
          contextNone = select(2, contextInfoForLine(annotations, required.line)),
          require = required,
        })
      end
    end

    table.insert(scripts, script)
    byPath[path] = script
  end

  local project = {
    roots = table.clone(roots),
    workspace = workspace,
    requireEdges = requireEdges,
    manifests = manifests,
    contentConfigs = contentConfigs,
    declarations = declarations,
    scripts = scripts,
    byPath = byPath,
  }

  return project
end

return table.freeze {
  build = build,
  parseContextExpression = parseContextExpression,
  contextAnnotations = contextAnnotations,
  contextsForLine = contextsForLine,
  contextInfoForLine = contextInfoForLine,
  contextList = setList,
  contextSet = setFrom,
  contextContains = setContains,
  contextOverlap = contextsOverlap,
  recordFields = recordFields,
  resolved = resolved,
  literalString = literalString,
  normalizeLuaDialect = normalizeOpenmwLua,
}
