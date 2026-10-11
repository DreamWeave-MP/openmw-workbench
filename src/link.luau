--!strict
--!native
-- Source <-> content linker. This module is intentionally conservative: it only emits
-- source/data edges when a literal OpenMW API argument or a record field decoded by the tes3
-- package gives us a concrete identity. Unresolved references remain facts, not missing-content errors,
-- because the active game load order may contain content outside the inspected roots.
local style = require '@jess/style'
local analysis = style.analysis
local model = require '@openmw/workbench/model'
local content = require '@openmw/workbench/content'
local knowledge = require '@openmw/workbench/knowledge'

type NifTexture = {
  record: number,
  value: string,
  resolved: string?,
  candidates: { string },
  resolution: string,
}

--- What decoding one NIF found: how much of it is reachable and the textures it names, or why it
--- could not be read.
type NifInspection = {
  path: string,
  ok: boolean,
  reachableRecords: number?,
  textures: { NifTexture },
  error: string?,
  textureError: string?,
}

type AssetLink = {
  field: string,
  value: string,
  resolved: string?,
  candidates: { string },
  nif: NifInspection?,
}

type RecordLink = { field: string, value: string, matches: { IndexedRecord } }

--- One record of an inspected plugin, under the identity the tes3 package gives it.
type IndexedRecord = {
  id: string,
  normalizedId: string,
  index: number,
  plugin: string,
  type: string?,
  tag: string?,
  fields: { content.StringField },
  assetLinks: { AssetLink },
  recordLinks: { RecordLink },
}

local AssetFieldRoots: { [string]: string } = {
  mesh = 'meshes',
  model = 'meshes',
  icon = 'icons',
  texture = 'textures',
  sound = 'sound',
}

local AssetExtensions: { [string]: boolean } = {
  nif = true,
  dds = true,
  tga = true,
  png = true,
  jpg = true,
  jpeg = true,
  bmp = true,
  wav = true,
  mp3 = true,
  ogg = true,
  flac = true,
  omwfx = true,
}

local RecordFieldNames: { [string]: boolean } = {
  body = true,
  script = true,
  enchant = true,
  owner = true,
  faction = true,
  race = true,
  class = true,
  spell = true,
  region = true,
  cell = true,
  key = true,
  creature = true,
  npc = true,
  item = true,
}

local function normalized(path: string): string
  return string.lower(string.gsub(path, '\\', '/'))
end

local function fileExtension(path: string): string?
  local extension = string.match(string.lower(path), '%.([a-z0-9_]+)$')
  return extension
end

local function looksLikeAsset(path: string): boolean
  local extension = fileExtension(path)
  return extension ~= nil and AssetExtensions[extension] == true
end

local function isSkippedDirectory(name: string): boolean
  local lower = string.lower(name)
  return string.sub(name, 1, 1) == '.' or lower == 'target' or lower == 'node_modules' or lower == 'backups' or lower == 'ignore'
end

local function collectPlugins(roots: { string }): { string }
  local found = {}

  local function visit(path: string)
    if jess.fs.isDir(path) then
      for _, name in jess.fs.list(path) do
        if isSkippedDirectory(name) then continue end
        visit(jess.fs.join(path, name))
      end
      return
    end

    if not jess.fs.isFile(path) then return end
    local lower = string.lower(path)
    if string.find(lower, '%.omwaddon$') or string.find(lower, '%.omwgame$') or string.find(lower, '%.esp$') or string.find(lower, '%.esm$') then
      table.insert(found, path)
    end
  end

  for _, root in roots do visit(root) end
  table.sort(found)
  return found
end

local function recordType(plugin, index: number): (string?, string?)
  -- display.display can reject unsupported record layouts; keep the record with unknown type instead.
  local ok, value = pcall(content.tes3.display.display, plugin, index)
  if not ok or type(value) ~= 'table' then return nil, nil end
  local name = if type(value.type) == 'string' then value.type else nil
  if not name then return nil, nil end

  for _, spec in content.tes3.recordTypes do
    if spec.name == name then return name, spec.tag end
  end
  return name, nil
end

local function recordId(plugin, index: number): string?
  -- records.id can reject record kinds without a canonical ID; skip those records and keep indexing.
  local ok, value = pcall(content.tes3.records.id, plugin, index)
  if not ok or type(value) ~= 'string' or value == '' then return nil end
  return value
end

local function recordStrings(plugin, index: number): { content.StringField }
  -- stringFields can reject unsupported record layouts; an empty field set still leaves the record indexable.
  local ok, fields = pcall(content.tes3.records.stringFields, plugin, index)
  if not ok or type(fields) ~= 'table' then return {} end
  return fields
end

local function assetCandidates(fieldName: string?, path: string): { string }
  local result = {}
  local seen: { [string]: boolean } = {}
  local raw = normalized(path)

  local function add(value: string)
    if value == '' or seen[value] then return end
    seen[value] = true
    table.insert(result, value)
  end

  add(raw)
  if fieldName then
    local root = AssetFieldRoots[string.lower(fieldName)]
    if root and string.sub(raw, 1, #root + 1) ~= `{root}/` then add(`{root}/{raw}`) end
  end
  return result
end

local function resolveAsset(vfs, fieldName: string?, path: string)
  local candidates = assetCandidates(fieldName, path)
  for _, candidate in candidates do
    -- VFS lookup can reject malformed paths; unresolved candidates remain useful linker facts.
    local ok, exists = pcall(function() return vfs:contains(candidate) end)
    if ok and exists then return candidate, candidates end
  end
  return nil, candidates
end

local function inspectNif(index, path: string): NifInspection
  local key = normalized(path)
  local cached = index.nifCache[key]
  if cached then return cached end

  local result: NifInspection = {
    path = path,
    ok = false,
    reachableRecords = nil,
    textures = {},
    error = nil,
  }
  index.nifCache[key] = result

  -- VFS file lookup can reject malformed paths; preserve the failed inspection as linker evidence.
  local okFile, file = pcall(function() return index.vfs:getFile(path) end)
  if not okFile or not file then
    result.error = if okFile then 'VFS entry disappeared after resolution' else tostring(file)
    return result
  end

  -- Loose/archive reads can fail on I/O or corrupt archive entries; one bad asset must not abort the project link.
  local okBytes, bytes = pcall(function() return file:readAllBuffer() end)
  if not okBytes then
    result.error = tostring(bytes)
    return result
  end

  -- NIF decoding rejects corrupt or unsupported files; keep that failure attached to the source edge.
  local okNif, nif = pcall(content.nif.open, bytes)
  if not okNif then
    result.error = tostring(nif)
    return result
  end

  result.ok = true

  -- Reachability walks NIF links and can reject corrupt decoded records; texture inspection is still useful if it fails.
  local okReachable, reachable = pcall(function() return nif:reachableCount() end)
  if okReachable then result.reachableRecords = reachable end

  -- Texture decoding can reject malformed NiSourceTexture records; report a partial NIF inspection instead of aborting.
  local okTextures, textures = pcall(function() return nif:textures() end)
  if okTextures then
    for _, texture in textures do
      local resolved, candidates = resolveAsset(index.vfs, 'texture', texture.path)
      table.insert(result.textures, {
        record = texture.record,
        value = texture.path,
        resolved = resolved,
        candidates = candidates,
        resolution = if resolved then 'local' else 'external-or-missing',
      })
    end
  else
    result.textureError = tostring(textures)
  end

  return result
end

local function buildIndex(roots: { string })
  local vfs = content.vfs.VFS.fromDirectories(roots)
  local plugins = collectPlugins(roots)
  local records: { IndexedRecord } = {}
  local byRecordId: { [string]: { IndexedRecord } } = {}
  local failures = {}

  for _, path in plugins do
    -- Plugin decoding can reject malformed/unsupported content; record the failure and index the rest.
    local ok, plugin = pcall(content.openPlugin, path)
    if not ok then
      table.insert(failures, { path = path, error = tostring(plugin) })
      continue
    end

    for index = 1, #plugin.parts do
      local id = recordId(plugin, index)
      if not id then continue end
      local typeName, typeTag = recordType(plugin, index)
      local fields = recordStrings(plugin, index)
      local record: IndexedRecord = {
        id = id,
        normalizedId = string.lower(id),
        index = index,
        plugin = path,
        type = typeName,
        tag = typeTag,
        fields = fields,
        assetLinks = {},
        recordLinks = {},
      }
      table.insert(records, record)
      byRecordId[record.normalizedId] = byRecordId[record.normalizedId] or {}
      table.insert(byRecordId[record.normalizedId], record)
    end
  end

  -- Resolve data-world edges after every record identity is known. A relation is only
  -- emitted for named fields with stable semantics or for asset-like fields.
  for _, record in records do
    for _, field in record.fields do
      local name = if type(field.name) == 'string' then string.lower(field.name) else ''
      local value = if type(field.value) == 'string' then field.value else nil
      if not value or value == '' then continue end

      if RecordFieldNames[name] then
        local matches = byRecordId[string.lower(value)]
        if matches then
          table.insert(record.recordLinks, {
            field = name,
            value = value,
            matches = matches,
          })
        end
      end

      if AssetFieldRoots[name] or looksLikeAsset(value) then
        local resolved, candidates = resolveAsset(vfs, name, value)
        table.insert(record.assetLinks, {
          field = name,
          value = value,
          resolved = resolved,
          candidates = candidates,
        })
      end
    end
  end

  local index = {
    roots = table.clone(roots),
    vfs = vfs,
    plugins = plugins,
    records = records,
    byRecordId = byRecordId,
    failures = failures,
    nifCache = {},
  }

  -- Mesh-bearing records give us a second deterministic route into the NIF graph.
  -- Decode only assets that actually resolve in the inspected VFS; base-game/external
  -- assets remain unresolved facts rather than false missing-content diagnostics.
  for _, record in records do
    for _, asset in record.assetLinks do
      if asset.resolved and fileExtension(asset.resolved) == 'nif' then
        asset.nif = inspectNif(index, asset.resolved)
      end
    end
  end

  return index
end

local function localModuleSource(project, fromPath: string, moduleName: string)
  for _, edge in project.requireEdges do
    if edge.from == fromPath and edge.module == moduleName then return project.workspace.byPath[edge.to] end
  end
  return nil
end

local function assignmentValue(source, target: string)
  local best = nil
  for _, assignment in source.assignments do
    if assignment.target ~= target or not assignment.value then continue end
    if assignment.functionDepth ~= 0 or assignment.loopDepth ~= 0 or assignment.conditionalDepth ~= 0 then continue end
    best = assignment.value
  end
  return best
end

local function returnedValue(source)
  local returned = source.moduleReturn
  if not returned then return nil end
  local resolved = analysis.resolve(source, returned)
  if resolved.kind == 'ExprGlobal' then return assignmentValue(source, resolved.name) or resolved end
  return resolved
end

local function exportedMember(source, memberPath: string)
  local current = returnedValue(source)
  if not current then return nil end
  local rootName = if source.moduleReturn and source.moduleReturn.kind == 'ExprGlobal' then source.moduleReturn.name else nil
  local prefix = ''

  for part in string.gmatch(memberPath, '[^.]+') do
    prefix = if prefix == '' then part else `{prefix}.{part}`
    local nextValue = analysis.resolvedTableField(source, current, part)
    if not nextValue and rootName then nextValue = assignmentValue(source, `{rootName}.{prefix}`) end
    if not nextValue then return nil end
    current = analysis.resolve(source, nextValue)
  end
  return current
end

local function workspaceValue(project, source, expr, depth: number?)
  if not expr then return nil end
  local left = depth or 16
  if left <= 0 then return nil end
  local current = analysis.resolve(source, expr)
  if current.kind == 'ExprConstantString' or current.kind == 'ExprConstantInteger' or current.kind == 'ExprConstantNumber' then return current end

  if current.kind == 'ExprIndexName' then
    local _, moduleName, member = analysis.qualifiedPath(current, source.origins)
    if moduleName and member and not string.find(moduleName, '^openmw%.') and source.path then
      local target = localModuleSource(project, source.path, moduleName)
      if target then
        local exported = exportedMember(target, member)
        if exported then return workspaceValue(project, target, exported, left - 1) end
      end
    end
  end
  return current
end

local function workspaceString(project, source, expr): string?
  local value = workspaceValue(project, source, expr)
  if value and value.kind == 'ExprConstantString' then return value.value end
  return nil
end

local function workspaceNumber(project, source, expr): number?
  local value = workspaceValue(project, source, expr)
  if value and (value.kind == 'ExprConstantInteger' or value.kind == 'ExprConstantNumber') then return value.value end
  return nil
end

local function parameterIndex(member, names: { [string]: boolean }): number?
  if not member or type(member.params) ~= 'table' then return nil end

  for index, name in member.params do
    if names[string.lower(name)] then return index end
  end
  return nil
end

local function sourceRecordFacts(project, index)
  local facts = {}
  local recordNames = { recordid = true, objectorrecordid = true }

  for _, script in project.scripts do
    for _, call in script.source.calls do
      if not call.module or not call.member then continue end
      local member = knowledge.memberContract(call.module, call.member)
      local recordParam = parameterIndex(member, recordNames)
      if recordParam then
        local value = workspaceString(project, script.source, call.expr.args[recordParam])
        if value then
          local matches = index.byRecordId[string.lower(value)] or {}
          local typeHint = nil
          if call.module == 'openmw.types' then typeHint = string.match(call.member, '^([^.]+)%.record$') end

          table.insert(facts, {
            script = script,
            line = call.line,
            kind = call.member,
            id = value,
            normalizedId = string.lower(value),
            typeHint = typeHint,
            matches = matches,
            resolution = if #matches > 0 then 'local' else 'external-or-missing',
            call = call,
          })
        end
      end

      if call.module == 'openmw.core' and call.member == 'getFormId' then
        local file = workspaceString(project, script.source, call.expr.args[1])
        local numericIndex = workspaceNumber(project, script.source, call.expr.args[2])
        if file then
          table.insert(facts, {
            script = script,
            line = call.line,
            kind = 'form-id',
            contentFile = file,
            index = numericIndex,
            call = call,
          })
        end
      end
    end
  end

  return facts
end

local function sourceAssetFacts(project, index)
  local facts = {}
  local seen: { [string]: boolean } = {}

  local function add(script, line: number, kind: string, field: string?, value: string)
    local key = `{script.path}:{line}:{kind}:{field or ''}:{value}`
    if seen[key] then return end
    seen[key] = true
    local resolved, candidates = resolveAsset(index.vfs, field, value)
    local matches = nil
    if kind == 'vfs-pathsWithPrefix' then
      -- VFS prefix enumeration can fail on malformed providers; unresolved remains a valid external-content fact.
      local ok, prefixMatches = pcall(function() return index.vfs:pathsWith(normalized(value)) end)
      if ok and type(prefixMatches) == 'table' and #prefixMatches > 0 then
        matches = prefixMatches
        resolved = normalized(value)
      end
    end
    local nif = nil
    if resolved and fileExtension(resolved) == 'nif' then nif = inspectNif(index, resolved) end

    table.insert(facts, {
      script = script,
      line = line,
      kind = kind,
      field = field,
      value = value,
      resolved = resolved,
      candidates = candidates,
      matches = matches,
      nif = nif,
      resolution = if resolved then 'local' else 'external-or-missing',
    })
  end

  for _, script in project.scripts do
    for _, call in script.source.calls do
      if call.module ~= 'openmw.vfs' or not call.member then continue end
      local member = knowledge.memberContract(call.module, call.member)
      local pathParam = parameterIndex(member, { filename = true, path = true })
      if not pathParam then continue end
      local value = workspaceString(project, script.source, call.expr.args[pathParam])
      if value then add(script, call.line, `vfs-{call.member}`, nil, value) end
    end

    for _, tableFact in script.source.tables do
      for _, item in tableFact.expr.items do
        if item.itemKind ~= 'record' or not item.key or item.key.kind ~= 'ExprConstantString' then continue end
        local field = string.lower(item.key.value)
        if not AssetFieldRoots[field] and field ~= 'path' and field ~= 'file' and field ~= 'filename' then continue end
        local value = workspaceString(project, script.source, item.value)
        if value and looksLikeAsset(value) then add(script, item.line, 'table-field', field, value) end
      end
    end

    -- Asset paths are often values inside semantic lookup tables (`grand = '...nif'`)
    -- where the key says nothing about the value's role. AST string facts exclude
    -- comments, so extension-gated literals are cheap deterministic VFS candidates.
    for _, literal in script.source.strings do
      if looksLikeAsset(literal.value) then add(script, literal.line, 'asset-literal', nil, literal.value) end
    end
  end

  return facts
end

local function build(project)
  local index = buildIndex(project.roots)
  local recordReferences = sourceRecordFacts(project, index)
  local assetReferences = sourceAssetFacts(project, index)
  local resolvedRecords, resolvedAssets = 0, 0
  local parsedNifs, failedNifs, nifTextures, resolvedNifTextures = 0, 0, 0, 0
  for _, fact in recordReferences do if fact.matches and #fact.matches > 0 then resolvedRecords += 1 end end
  for _, fact in assetReferences do if fact.resolved then resolvedAssets += 1 end end

  for _, nif in index.nifCache do
    if nif.ok then
      parsedNifs += 1
    else
      failedNifs += 1
    end
    nifTextures += #nif.textures
    for _, texture in nif.textures do if texture.resolved then resolvedNifTextures += 1 end end
  end

  return {
    index = index,
    recordReferences = recordReferences,
    assetReferences = assetReferences,
    summary = {
      plugins = #index.plugins,
      records = #index.records,
      pluginFailures = #index.failures,
      sourceRecordReferences = #recordReferences,
      resolvedSourceRecords = resolvedRecords,
      sourceAssetReferences = #assetReferences,
      resolvedSourceAssets = resolvedAssets,
      parsedSourceNifs = parsedNifs,
      failedSourceNifs = failedNifs,
      sourceNifTextureReferences = nifTextures,
      resolvedSourceNifTextures = resolvedNifTextures,
    },
  }
end

return table.freeze {
  build = build,
  buildIndex = buildIndex,
  normalizeVfsPath = normalized,
}
