--!strict
--!native
local model = require '@openmw/workbench/model'

local function addNode(nodes, seen, id: string, kind: string, label: string, metadata)
  if seen[id] then return end
  seen[id] = true
  table.insert(nodes, { id = id, kind = kind, label = label, metadata = metadata })
end

local function build(project, linked)
  local nodes, edges, seen = {}, {}, {}

  for _, script in project.scripts do
    local scriptId = `script:{script.path}`
    addNode(nodes, seen, scriptId, 'script', script.path, { contexts = model.contextList(script.contexts) })

    for _, required in script.source.requires do
      local moduleId = `module:{required.module}`
      addNode(nodes, seen, moduleId, 'module', required.module, nil)
      table.insert(edges, { from = scriptId, to = moduleId, kind = 'requires', line = required.line })
    end

    for _, event in script.sentEvents do
      local eventId = `event:{event.name}`
      addNode(nodes, seen, eventId, 'event', event.name, nil)
      table.insert(edges, { from = scriptId, to = eventId, kind = 'sends-event', line = event.line })
    end

    for _, handler in script.eventHandlers do
      local eventId = `event:{handler.name}`
      addNode(nodes, seen, eventId, 'event', handler.name, nil)
      table.insert(edges, { from = eventId, to = scriptId, kind = 'handles-event', line = handler.line })
    end

    if script.interface then
      local interfaceId = `interface:{script.interface.name}`
      addNode(nodes, seen, interfaceId, 'interface', script.interface.name, nil)
      table.insert(edges, { from = scriptId, to = interfaceId, kind = 'provides-interface', line = script.interface.line })
    end

    for _, section in script.storageSections do
      local name = section.section or `<dynamic:{section.binding}>`
      local storageId = `storage:{section.scope}:{name}`
      addNode(nodes, seen, storageId, 'storage', `{section.scope}:{name}`, nil)
      table.insert(edges, { from = scriptId, to = storageId, kind = 'uses-storage', line = section.line })
    end
  end

  for _, edge in project.requireEdges do
    local fromId, toId = `script:{edge.from}`, `script:{edge.to}`
    addNode(nodes, seen, fromId, 'script', edge.from, nil)
    addNode(nodes, seen, toId, 'script', edge.to, nil)
    table.insert(edges, { from = fromId, to = toId, kind = 'local-require', line = edge.line })
  end

  if linked then
    for _, plugin in linked.index.plugins do
      local pluginId = `plugin:{plugin}`
      addNode(nodes, seen, pluginId, 'plugin', plugin, nil)
    end

    for _, record in linked.index.records do
      local recordId = `record:{record.plugin}:{record.index}`
      local pluginId = `plugin:{record.plugin}`
      addNode(nodes, seen, pluginId, 'plugin', record.plugin, nil)
      addNode(nodes, seen, recordId, 'record', record.id, { type = record.type, tag = record.tag, plugin = record.plugin })
      table.insert(edges, { from = pluginId, to = recordId, kind = 'defines-record', line = 0 })

      for _, relation in record.recordLinks do
        for _, target in relation.matches do
          local targetId = `record:{target.plugin}:{target.index}`
          addNode(nodes, seen, targetId, 'record', target.id, { type = target.type, tag = target.tag, plugin = target.plugin })
          table.insert(edges, { from = recordId, to = targetId, kind = `record-field:{relation.field}`, line = 0 })
        end
      end

      for _, asset in record.assetLinks do
        local path = asset.resolved or asset.value
        local assetId = `asset:{string.lower(string.gsub(path, '\\', '/'))}`
        local nif = asset.nif
        addNode(nodes, seen, assetId, 'asset', path, {
          resolved = asset.resolved ~= nil,
          field = asset.field,
          nifParsed = if nif then nif.ok else nil,
          nifReachableRecords = if nif then nif.reachableRecords else nil,
        })
        table.insert(edges, { from = recordId, to = assetId, kind = `record-asset:{asset.field}`, line = 0 })

        if nif and nif.ok then
          for _, texture in nif.textures do
            local texturePath = texture.resolved or texture.value
            local textureId = `asset:{string.lower(string.gsub(texturePath, '\\', '/'))}`
            addNode(nodes, seen, textureId, 'asset', texturePath, {
              resolved = texture.resolved ~= nil,
              kind = 'nif-texture',
            })

            table.insert(edges, {
              from = assetId,
              to = textureId,
              kind = 'nif-texture',
              line = 0,
              record = texture.record,
            })
          end
        end
      end
    end

    for _, reference in linked.recordReferences do
      if not reference.script then continue end
      local scriptId = `script:{reference.script.path}`
      if reference.matches and #reference.matches > 0 then
        for _, record in reference.matches do
          local recordId = `record:{record.plugin}:{record.index}`
          addNode(nodes, seen, recordId, 'record', record.id, { type = record.type, tag = record.tag, plugin = record.plugin })
          table.insert(edges, { from = scriptId, to = recordId, kind = 'references-record', line = reference.line })
        end
      elseif reference.id then
        local unresolvedId = `record-ref:{string.lower(reference.id)}`
        addNode(nodes, seen, unresolvedId, 'record-reference', reference.id, { resolution = reference.resolution })
        table.insert(edges, { from = scriptId, to = unresolvedId, kind = 'references-record', line = reference.line })
      elseif reference.contentFile then
        local contentId = `content-file:{string.lower(reference.contentFile)}`
        addNode(nodes, seen, contentId, 'content-file', reference.contentFile, { index = reference.index })
        table.insert(edges, { from = scriptId, to = contentId, kind = 'constructs-form-id', line = reference.line })
      end
    end

    for _, reference in linked.assetReferences do
      local scriptId = `script:{reference.script.path}`
      local path = reference.resolved or reference.value
      local assetId = `asset:{string.lower(string.gsub(path, '\\', '/'))}`
      local nif = reference.nif
      addNode(nodes, seen, assetId, 'asset', path, {
        resolved = reference.resolved ~= nil,
        kind = reference.kind,
        nifParsed = if nif then nif.ok else nil,
        nifReachableRecords = if nif then nif.reachableRecords else nil,
      })

      table.insert(edges, { from = scriptId, to = assetId, kind = 'references-asset', line = reference.line })

      if nif and nif.ok then
        for _, texture in nif.textures do
          local texturePath = texture.resolved or texture.value
          local textureId = `asset:{string.lower(string.gsub(texturePath, '\\', '/'))}`
          addNode(nodes, seen, textureId, 'asset', texturePath, {
            resolved = texture.resolved ~= nil,
            kind = 'nif-texture',
          })

          table.insert(edges, {
            from = assetId,
            to = textureId,
            kind = 'nif-texture',
            line = 0,
            record = texture.record,
          })
        end
      end
    end
  end

  table.sort(nodes, function(left, right) return left.id < right.id end)
  table.sort(edges, function(left, right)
    if left.from ~= right.from then return left.from < right.from end
    if left.to ~= right.to then return left.to < right.to end
    if left.kind ~= right.kind then return left.kind < right.kind end
    return (left.line or 0) < (right.line or 0)
  end)

  return { nodes = nodes, edges = edges }
end

return table.freeze { build = build }
