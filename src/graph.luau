--!strict
--!native
local model = require '@openmw/workbench/model'

local function addNode(nodes, seen, id: string, kind: string, label: string, metadata)
  if seen[id] then return end
  seen[id] = true
  table.insert(nodes, { id = id, kind = kind, label = label, metadata = metadata })
end

local function build(project)
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

  for _, edge in project.workspace.requireEdges do
    local fromId, toId = `script:{edge.from}`, `script:{edge.to}`
    addNode(nodes, seen, fromId, 'script', edge.from, nil)
    addNode(nodes, seen, toId, 'script', edge.to, nil)
    table.insert(edges, { from = fromId, to = toId, kind = 'local-require', line = edge.line })
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
