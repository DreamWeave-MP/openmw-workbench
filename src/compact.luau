--!strict
--!native
-- Integer-backed, queryable semantic index for large source universes.
-- ASTs are transient compiler input: this module lowers useful facts into compact buffers and
-- native intern pools, then exposes them through JessQL providers.
local style = require '@jess/style'
local analysis = style.analysis
local sql = require '@jessql'
local intern = require '@dream/intern'

local ChunkRows = 16384
local U8Sentinel = 255
local U16Sentinel = 65535
local U24Limit = 16777215
local U18Sentinel = 262143
local U14Sentinel = 16383
local Width = { u8 = 1, u16 = 2, u24 = 3, u32 = 4 }

local function writeU24(target: buffer, offset: number, value: number)
  buffer.writeu16(target, offset, value % 65536)
  buffer.writeu8(target, offset + 2, math.floor(value / 65536))
end

local function readU24(source: buffer, offset: number): number
  return buffer.readu16(source, offset) + buffer.readu8(source, offset + 2) * 65536
end

local function writeValue(target: buffer, offset: number, kind: string, value: number)
  if kind == 'u8' then buffer.writeu8(target, offset, value)
  elseif kind == 'u16' then buffer.writeu16(target, offset, value)
  elseif kind == 'u24' then writeU24(target, offset, value)
  else buffer.writeu32(target, offset, value) end
end

local function readValue(source: buffer, offset: number, kind: string): number
  if kind == 'u8' then return buffer.readu8(source, offset) end
  if kind == 'u16' then return buffer.readu16(source, offset) end
  if kind == 'u24' then return readU24(source, offset) end
  return buffer.readu32(source, offset)
end

local function packed(spec, chunkRows: number?)
  local names, offsets, kinds = {}, {}, {}
  local rowWidth = 0
  for index, column in spec do
    names[index] = column[1]
    offsets[index] = rowWidth
    kinds[index] = column[2]
    rowWidth += Width[column[2]]
  end

  local rowsPerChunk = chunkRows or ChunkRows
  local store = {
    columns = names,
    offsets = offsets,
    kinds = kinds,
    rowWidth = rowWidth,
    rows = 0,
    chunks = {},
    rowsPerChunk = rowsPerChunk,
  }

  function store:add(values)
    local row0 = self.rows
    local chunkIndex = math.floor(row0 / self.rowsPerChunk) + 1
    local slot = row0 % self.rowsPerChunk
    local chunk = self.chunks[chunkIndex]
    if not chunk then
      chunk = buffer.create(self.rowWidth * self.rowsPerChunk)
      self.chunks[chunkIndex] = chunk
    end

    local base = slot * self.rowWidth
    for index = 1, #self.columns do
      writeValue(chunk, base + self.offsets[index], self.kinds[index], values[index] or 0)
    end
    self.rows += 1
    return row0 + 1
  end

  function store:get(row1: number, column: number): number
    local row0 = row1 - 1
    local chunkIndex = math.floor(row0 / self.rowsPerChunk) + 1
    local slot = row0 % self.rowsPerChunk
    return readValue(self.chunks[chunkIndex], slot * self.rowWidth + self.offsets[column], self.kinds[column])
  end

  function store:set(row1: number, column: number, value: number)
    local row0 = row1 - 1
    local chunkIndex = math.floor(row0 / self.rowsPerChunk) + 1
    local slot = row0 % self.rowsPerChunk
    writeValue(self.chunks[chunkIndex], slot * self.rowWidth + self.offsets[column], self.kinds[column], value)
  end

  function store:bytes(): number
    return #self.chunks * self.rowWidth * self.rowsPerChunk
  end

  return store
end

-- Reference rows are exactly 48 bits: 18-bit symbol id, 14-bit line, 8-bit column,
-- and one byte of semantic/depth metadata. Rare coordinate/symbol overflows spill into
-- sorted sidecars instead of widening the 1.6M-row hot table.
local function refStore()
  local store = { rows = 0, rowWidth = 6, chunks = {} }
  local lineOverflow = nil
  local columnOverflow = nil
  local symbolOverflow = nil

  local function overflowAdd(sidecar, row: number, value: number)
    if not sidecar then sidecar = packed({ { 'row', 'u24' }, { 'value', 'u24' } }, 1024) end
    sidecar:add { row, value }
    return sidecar
  end

  local function overflowGet(sidecar, row: number): number?
    if not sidecar then return nil end
    local low, high = 1, sidecar.rows
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local candidate = sidecar:get(middle, 1)
      if candidate < row then low = middle + 1
      elseif candidate > row then high = middle - 1
      else return sidecar:get(middle, 2) end
    end
    return nil
  end

  function store:add(values)
    local line, column, symbol, meta = values[1] or 0, values[2] or 0, values[3] or 0, values[4] or 0
    local row = self.rows + 1
    local storedLine = line
    if line >= U14Sentinel then storedLine = U14Sentinel; lineOverflow = overflowAdd(lineOverflow, row, line) end
    local storedColumn = column
    if column >= U8Sentinel then storedColumn = U8Sentinel; columnOverflow = overflowAdd(columnOverflow, row, column) end
    local storedSymbol = symbol
    if symbol >= U18Sentinel then storedSymbol = U18Sentinel; symbolOverflow = overflowAdd(symbolOverflow, row, symbol) end
    if meta > 255 then error(`compact reference metadata exceeded one byte: {meta}`) end

    local row0 = self.rows
    local chunkIndex = math.floor(row0 / ChunkRows) + 1
    local slot = row0 % ChunkRows
    local chunk = self.chunks[chunkIndex]
    if not chunk then chunk = buffer.create(self.rowWidth * ChunkRows); self.chunks[chunkIndex] = chunk end
    local base = slot * self.rowWidth
    local firstPacked = storedSymbol + (storedLine % 64) * 262144
    local secondPacked = math.floor(storedLine / 64) + storedColumn * 256 + meta * 65536
    writeU24(chunk, base, firstPacked)
    writeU24(chunk, base + 3, secondPacked)
    self.rows = row
    return row
  end

  local function pair(self, row1: number): (number, number)
    local row0 = row1 - 1
    local chunkIndex = math.floor(row0 / ChunkRows) + 1
    local slot = row0 % ChunkRows
    local base = slot * self.rowWidth
    local chunk = self.chunks[chunkIndex]
    return readU24(chunk, base), readU24(chunk, base + 3)
  end

  function store:get(row1: number, column: number): number
    local firstPacked, secondPacked = pair(self, row1)
    if column == 1 then
      local value = math.floor(firstPacked / 262144) + (secondPacked % 256) * 64
      if value == U14Sentinel then return overflowGet(lineOverflow, row1) or value end
      return value
    elseif column == 2 then
      local value = math.floor(secondPacked / 256) % 256
      if value == U8Sentinel then return overflowGet(columnOverflow, row1) or value end
      return value
    elseif column == 3 then
      local value = firstPacked % 262144
      if value == U18Sentinel then return overflowGet(symbolOverflow, row1) or value end
      return value
    elseif column == 4 then
      return math.floor(secondPacked / 65536) % 256
    end
    error(`compact reference column out of range: {column}`)
  end

  function store:bytes(): number return #self.chunks * self.rowWidth * ChunkRows end

  function store:overflowBytes(): number
    return (if lineOverflow then lineOverflow:bytes() else 0)
      + (if columnOverflow then columnOverflow:bytes() else 0)
      + (if symbolOverflow then symbolOverflow:bytes() else 0)
  end
  return store
end

-- Depths use a tiny dictionary of the first 63 distinct triples encountered. Code 63 is a sparse
-- overflow marker. In practice this replaces a fixed Cartesian encoding that overflowed on tens of
-- thousands of rows while preserving one metadata byte per reference.
local function depthCodec()
  local triples = packed({ { 'function_depth', 'u16' }, { 'loop_depth', 'u16' }, { 'conditional_depth', 'u16' } }, 64)
  local byKey = {}

  local codec = { triples = triples }
  function codec:encode(functionDepth: number, loopDepth: number, conditionalDepth: number): (number, boolean)
    if functionDepth > 65535 or loopDepth > 65535 or conditionalDepth > 65535 then return 63, true end
    local key = `{functionDepth}:{loopDepth}:{conditionalDepth}`
    local code = byKey[key]
    if code ~= nil then return code, false end

    if triples.rows < 63 then
      code = triples.rows
      triples:add { functionDepth, loopDepth, conditionalDepth }
      byKey[key] = code
      return code, false
    end
    return 63, true
  end

  function codec:decode(code: number): (number, number, number)
    local row = code + 1
    return triples:get(row, 1), triples:get(row, 2), triples:get(row, 3)
  end

  function codec:finishBuild() byKey = {} end
  return codec
end

local function refKind(meta: number): number return meta % 4 end
local function refDepthCode(meta: number): number return math.floor(meta / 4) % 64 end
local function requireDepthCode(meta: number): number return math.floor(meta / 2) % 64 end
local function protectedRequire(meta: number): boolean return meta % 2 == 1 end

-- Semantic-symbol rows are another exact 48-bit structure: 19-bit parent id, 17-bit atom id,
-- and a 12-bit module id. Module id 4095 is an overflow marker; late/rare module ids spill into
-- a packed sidecar. This replaces the previous 6-byte trie row plus 2-byte parallel module row.
local function symbolStore()
  local parentLimit = 524287
  local atomLimit = 131071
  local moduleSentinel = 4095
  local store = { rows = 0, rowWidth = 6, chunks = {} }
  local moduleOverflow = nil

  local function overflowAdd(row: number, value: number)
    if not moduleOverflow then moduleOverflow = packed({ { 'row', 'u24' }, { 'value', 'u16' } }, 1024) end
    moduleOverflow:add { row, value }
  end

  local function overflowGet(row: number): number?
    if not moduleOverflow then return nil end
    local low, high = 1, moduleOverflow.rows
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local candidate = moduleOverflow:get(middle, 1)
      if candidate < row then low = middle + 1
      elseif candidate > row then high = middle - 1
      else return moduleOverflow:get(middle, 2) end
    end
    return nil
  end

  local function writeRow(self, row1: number, parent: number, atom: number, moduleId: number)
    if parent >= parentLimit then error('compact semantic-symbol parent exceeded 19-bit identity space') end
    if atom >= atomLimit then error('compact semantic-symbol atom dictionary exceeded 17-bit identity space') end
    if moduleId >= U16Sentinel then error('compact module dictionary exceeded 16-bit identity space') end
    local storedModule = moduleId
    if moduleId >= moduleSentinel then storedModule = moduleSentinel end
    local packedValue = parent + atom * 524288 + storedModule * 68719476736
    local row0 = row1 - 1
    local chunkIndex = math.floor(row0 / ChunkRows) + 1
    local slot = row0 % ChunkRows
    local chunk = self.chunks[chunkIndex]
    if not chunk then chunk = buffer.create(self.rowWidth * ChunkRows); self.chunks[chunkIndex] = chunk end
    local base = slot * self.rowWidth
    writeU24(chunk, base, packedValue % 16777216)
    writeU24(chunk, base + 3, math.floor(packedValue / 16777216))
  end

  local function raw(self, row1: number): number
    local row0 = row1 - 1
    local chunkIndex = math.floor(row0 / ChunkRows) + 1
    local slot = row0 % ChunkRows
    local chunk = self.chunks[chunkIndex]
    local base = slot * self.rowWidth
    return readU24(chunk, base) + readU24(chunk, base + 3) * 16777216
  end

  function store:add(values)
    local row = self.rows + 1
    local parent, atom, moduleId = values[1] or 0, values[2] or 0, values[3] or 0
    writeRow(self, row, parent, atom, moduleId)
    if moduleId >= moduleSentinel then overflowAdd(row, moduleId) end
    self.rows = row
    return row
  end

  function store:get(row1: number, column: number): number
    local value = raw(self, row1)
    if column == 1 then return value % 524288 end
    if column == 2 then return math.floor(value / 524288) % 131072 end

    if column == 3 then
      local moduleId = math.floor(value / 68719476736) % 4096
      if moduleId == moduleSentinel then return overflowGet(row1) or moduleId end
      return moduleId
    end
    error(`compact symbol column out of range: {column}`)
  end

  function store:setModule(row1: number, moduleId: number)
    local parent, atom = self:get(row1, 1), self:get(row1, 2)
    writeRow(self, row1, parent, atom, moduleId)
    if moduleId >= moduleSentinel then overflowAdd(row1, moduleId) end
  end

  function store:bytes(): number return #self.chunks * self.rowWidth * ChunkRows end

  function store:overflowBytes(): number return if moduleOverflow then moduleOverflow:bytes() else 0 end
  return store
end

local function normalizeRoots(paths: { string } | string): { string }
  if type(paths) == 'string' then return { paths :: string } end
  return table.clone(paths)
end

local function build(paths: { string } | string, options)
  local given = options or {}
  local roots = normalizeRoots(paths)
  local files = analysis.files(roots, {
    extensions = given.extensions,
    skipDirectories = given.skipDirectories,
  })

  if #files >= U24Limit then error('compact index supports fewer than 16,777,215 source files') end

  local sourceKind = if #files <= 65534 then 'u16' else 'u24'

  -- Physical paths are prefix-heavy, so store them as a component trie instead of interning every
  -- absolute string. Backslashes remain literal filename bytes; only '/' is a physical separator.
  local rootPaths = table.create(#roots)
  for index, root in roots do
    while #root > 1 and string.sub(root, -1) == '/' do root = string.sub(root, 1, -2) end
    rootPaths[index] = root
  end
  local rootKind = if #rootPaths <= 254 then 'u8' else 'u16'
  local pathAtomPool = intern.new('exact')
  local pathAtomIntern = pathAtomPool:interner()
  local pathNodes = packed { { 'parent', 'u24' }, { 'atom', 'u24' } }
  local sourceByPathNode = packed { { 'source_id', sourceKind } }
  local sourcePathLeaf = packed { { 'leaf', 'u24' } }
  local sourceRoot = packed { { 'root_id', rootKind } }
  local pathEdgeCapacity = 512
  local pathEdgeSlots = buffer.create(pathEdgeCapacity * 3)
  local pathEdgeSize = 0

  local function pathEdgeStart(parent: number, atom: number): number
    return (parent * 65537 + atom * 114689) % pathEdgeCapacity
  end

  local function pathEdgeLookup(parent: number, atom: number): number?
    local slot = pathEdgeStart(parent, atom)
    local step = 1
    while true do
      local id = readU24(pathEdgeSlots, slot * 3)
      if id == 0 then return nil end
      if pathNodes:get(id, 1) == parent and pathNodes:get(id, 2) == atom then return id end
      slot = (slot + step) % pathEdgeCapacity
      step += 1
    end
  end

  local function pathEdgeInsertId(id: number)
    local parent, atom = pathNodes:get(id, 1), pathNodes:get(id, 2)
    local slot = pathEdgeStart(parent, atom)
    local step = 1
    while readU24(pathEdgeSlots, slot * 3) ~= 0 do
      slot = (slot + step) % pathEdgeCapacity
      step += 1
    end
    writeU24(pathEdgeSlots, slot * 3, id)
  end

  local function growPathEdges()
    pathEdgeCapacity *= 2
    pathEdgeSlots = buffer.create(pathEdgeCapacity * 3)
    for id = 1, pathNodes.rows do pathEdgeInsertId(id) end
  end

  local function pathEdge(parent: number, atom: number): number
    local existing = pathEdgeLookup(parent, atom)
    if existing then return existing end
    if pathNodes.rows + 1 >= U24Limit then error('compact path trie exceeded 24-bit identity space') end
    if (pathEdgeSize + 1) * 100 > pathEdgeCapacity * 78 then growPathEdges() end
    local id = pathNodes:add { parent, atom }
    sourceByPathNode:add { 0 }
    pathEdgeSize += 1
    pathEdgeInsertId(id)
    return id
  end

  local function rootAndRelative(path: string): (number?, string?)
    local best, bestLength = nil, -1
    for index, root in rootPaths do
      local rootLength = #root
      if rootLength > bestLength and (path == root or (string.sub(path, 1, rootLength) == root and string.sub(path, rootLength + 1, rootLength + 1) == '/')) then
        best, bestLength = index, rootLength
      end
    end

    if not best then return nil, nil end
    local relative = if #path == bestLength then '' else string.sub(path, bestLength + 2)
    return best, relative
  end

  local function pathLeaf(relative: string, create: boolean): number?
    if relative == '' then return 0 end
    local parent, first = 0, 1
    while true do
      local slash = string.find(relative, '/', first, true)
      local segment = if slash then string.sub(relative, first, slash - 1) else string.sub(relative, first)
      local atom = if create then pathAtomIntern(segment) else pathAtomPool:find(segment)
      if not atom then return nil end
      parent = if create then pathEdge(parent, atom) else pathEdgeLookup(parent, atom)
      if not parent then return nil end
      if not slash then break end
      first = slash + 1
    end
    return parent
  end

  local function internPath(sourceId: number, path: string)
    local rootId, relative = rootAndRelative(path)
    if not rootId or relative == nil then error(`compact index: source path escaped configured roots: {path}`) end
    local leaf = pathLeaf(relative, true) or 0
    if leaf == 0 then error(`compact index: source path cannot equal a source root: {path}`) end
    if sourceByPathNode:get(leaf, 1) ~= 0 then error(`compact index: duplicate physical source path: {path}`) end
    sourceByPathNode:set(leaf, 1, sourceId)
    if sourcePathLeaf:add { leaf } ~= sourceId or sourceRoot:add { rootId } ~= sourceId then
      error('compact path/source identity lost dense alignment')
    end
  end

  local function sourcePath(sourceId: number): string
    local leaf = sourcePathLeaf:get(sourceId, 1)
    local parts = {}
    while leaf ~= 0 do
      parts[#parts + 1] = pathAtomPool:resolve(pathNodes:get(leaf, 2))
      leaf = pathNodes:get(leaf, 1)
    end
    local left, right = 1, #parts
    while left < right do parts[left], parts[right] = parts[right], parts[left]; left += 1; right -= 1 end
    local root = rootPaths[sourceRoot:get(sourceId, 1)]
    if #parts == 0 then return root end
    return root .. '/' .. table.concat(parts, '/')
  end

  local function findSourcePath(path: string): number?
    local _, relative = rootAndRelative(path)
    if relative == nil then return nil end
    local leaf = pathLeaf(relative, false)
    if not leaf or leaf == 0 then return nil end
    local sourceId = sourceByPathNode:get(leaf, 1)
    if sourceId == 0 then return nil end
    return sourceId
  end
  local modulePool = intern.new('exact')
  local moduleIntern = modulePool:interner()
  local atomPool = intern.new('exact')
  local atomIntern = atomPool:interner()
  local symbolNodes = symbolStore()

  -- The symbol trie edge key is already two integers. A general intern pool wastes most of its
  -- memory on hash-table/string machinery, so keep only a 24-bit symbol id in each hash slot and
  -- verify the key against symbolNodes. No tombstones are needed because edges are append-only.
  local edgeCapacity = 1024
  local edgeSlots = buffer.create(edgeCapacity * 3)
  local edgeSize = 0

  local function edgeStart(parent: number, atom: number, capacity: number): number
    return (parent * 104729 + atom * 130363) % capacity
  end

  local function edgeLookup(parent: number, atom: number): number?
    local slot = edgeStart(parent, atom, edgeCapacity)
    local step = 1
    while true do
      local id = readU24(edgeSlots, slot * 3)
      if id == 0 then return nil end
      if symbolNodes:get(id, 1) == parent and symbolNodes:get(id, 2) == atom then return id end
      slot = (slot + step) % edgeCapacity
      step += 1
    end
  end

  local function edgeInsertId(id: number)
    local parent = symbolNodes:get(id, 1)
    local atom = symbolNodes:get(id, 2)
    local slot = edgeStart(parent, atom, edgeCapacity)
    local step = 1
    while readU24(edgeSlots, slot * 3) ~= 0 do
      slot = (slot + step) % edgeCapacity
      step += 1
    end
    writeU24(edgeSlots, slot * 3, id)
  end

  local function growEdges()
    local oldCapacity = edgeCapacity
    edgeCapacity *= 2
    edgeSlots = buffer.create(edgeCapacity * 3)
    for id = 1, symbolNodes.rows do edgeInsertId(id) end
    if oldCapacity >= edgeCapacity then error('compact symbol edge hash failed to grow') end
  end

  local function edge(parent: number, atom: number): number
    local existing = edgeLookup(parent, atom)
    if existing then return existing end
    if symbolNodes.rows + 1 >= U24Limit then error('compact semantic-symbol trie exceeded 24-bit identity space') end
    if (edgeSize + 1) * 100 > edgeCapacity * 78 then growEdges() end
    local id = symbolNodes:add { parent, atom, 0 }
    edgeSize += 1
    edgeInsertId(id)
    return id
  end

  local function symbolPath(text: string?): number
    if not text or text == '' then return 0 end
    local parent, first = 0, 1
    while true do
      local dot = string.find(text, '.', first, true)
      local segment = if dot then string.sub(text, first, dot - 1) else string.sub(text, first)
      parent = edge(parent, atomIntern(segment))
      if not dot then break end
      first = dot + 1
    end
    return parent
  end

  local function findSymbol(text: string?): number?
    if not text or text == '' then return 0 end
    local parent, first = 0, 1
    while true do
      local dot = string.find(text, '.', first, true)
      local segment = if dot then string.sub(text, first, dot - 1) else string.sub(text, first)
      local atom = atomPool:find(segment)
      if not atom then return nil end
      parent = edgeLookup(parent, atom)
      if not parent then return nil end
      if not dot then break end
      first = dot + 1
    end
    return parent
  end

  local function symbolText(id: number): string?
    if id == 0 then return nil end
    local parts = {}
    while id ~= 0 do
      table.insert(parts, atomPool:resolve(symbolNodes:get(id, 2)))
      id = symbolNodes:get(id, 1)
    end
    local left, right = 1, #parts
    while left < right do
      parts[left], parts[right] = parts[right], parts[left]
      left += 1
      right -= 1
    end
    return table.concat(parts, '.')
  end

  local function semanticSymbol(target: string?, moduleName: string?): number
    local symbol = symbolPath(target)
    if symbol ~= 0 and moduleName then
      local moduleId = moduleIntern(moduleName)
      if moduleId >= U16Sentinel then error('compact module dictionary exceeded 16-bit identity space') end
      if symbolNodes:get(symbol, 3) == 0 then symbolNodes:setModule(symbol, moduleId) end
    end
    return symbol
  end

  -- Every row is integer-only. Source identity on refs/requires is implicit from source ranges.
  local sources = packed {
    { 'bytes', 'u32' },
    { 'parse_errors', 'u16' },
    { 'refs_start', 'u32' },
    { 'refs_count', 'u24' },
    { 'calls', 'u24' },
    { 'members', 'u24' },
    { 'requires_start', 'u32' },
    { 'requires_count', 'u24' },
    { 'tables', 'u24' },
    { 'functions', 'u24' },
    { 'strings', 'u32' },
    { 'assignments', 'u24' },
  }

  local refs = refStore()

  local requires = packed {
    { 'line', 'u16' },
    { 'module_id', 'u16' },
    { 'target_source_id', sourceKind },
    { 'meta', 'u8' },
  }

  local depths = depthCodec()
  local refDepthOverflow = nil
  local requireLineOverflow, requireDepthOverflow = nil, nil

  -- Sparse coordinate overflow stays integer-only. The common case pays one byte for columns;
  -- pathological minified lines spill into a tiny sorted side stream.
  local function overflowAdd(store, row: number, value: number)
    if not store then store = packed({ { 'row', 'u24' }, { 'value', 'u24' } }, 1024) end
    store:add { row, value }
    return store
  end

  local function overflowGet(store, row: number): number?
    if not store then return nil end
    local low, high = 1, store.rows
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local candidate = store:get(middle, 1)
      if candidate < row then low = middle + 1
      elseif candidate > row then high = middle - 1
      else return store:get(middle, 2) end
    end
    return nil
  end

  local function storedRequireLine(value: number, row: number): number
    if value < U16Sentinel then return value end
    requireLineOverflow = overflowAdd(requireLineOverflow, row, value)
    return U16Sentinel
  end

  local function requireLine(row: number): number
    local value = requires:get(row, 1)
    if value == U16Sentinel then return overflowGet(requireLineOverflow, row) or value end
    return value
  end

  local function depthOverflowAdd(store, row: number, functionDepth: number, loopDepth: number, conditionalDepth: number)
    if not store then
      store = packed({ { 'row', 'u24' }, { 'function_depth', 'u16' }, { 'loop_depth', 'u16' }, { 'conditional_depth', 'u16' } }, 1024)
    end

    if functionDepth > 65535 or loopDepth > 65535 or conditionalDepth > 65535 then
      error('compact nesting depth exceeded 16-bit overflow representation')
    end
    store:add { row, functionDepth, loopDepth, conditionalDepth }
    return store
  end

  local function depthOverflowGet(store, row: number): (number?, number?, number?)
    if not store then return nil, nil, nil end
    local low, high = 1, store.rows
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local candidate = store:get(middle, 1)
      if candidate < row then low = middle + 1
      elseif candidate > row then high = middle - 1
      else return store:get(middle, 2), store:get(middle, 3), store:get(middle, 4) end
    end
    return nil, nil, nil
  end

  local transform = given.transform

  local totalBytes, duplicatedCallMembers, callOnly = 0, 0, 0
  local started = os.clock()
  for sourceId, path in files do
    local text = jess.fs.read(path)
    if not text then error(`compact index: unreadable source {path}`) end
    totalBytes += #text
    internPath(sourceId, path)
    if transform then text = transform(text, path) end
    local source = analysis.analyze(text, { path = path })
    local refsStart = refs.rows + 1
    local requiresStart = requires.rows + 1

    -- Most member calls are otherwise retained twice by the semantic frontend. Merge them into one
    -- reference row whose 2-bit kind says member, call, or both.
    local memberCallees = {}
    for _, call in source.calls do
      if call.expr.func.kind == 'ExprIndexName' then memberCallees[call.expr.func] = call end
    end

    for _, member in source.members do
      local call = memberCallees[member.expr]
      local kind = if call then 3 else 1
      if call then memberCallees[member.expr] = nil; duplicatedCallMembers += 1 end
      local depthCode, depthOverflow = depths:encode(member.functionDepth, member.loopDepth, member.conditionalDepth)
      local meta = kind + depthCode * 4
      local row = refs.rows + 1
      refs:add {
        member.line,
        member.column,
        semanticSymbol(member.target, member.module),
        meta,
      }

      if depthOverflow then
        refDepthOverflow = depthOverflowAdd(refDepthOverflow, row, member.functionDepth, member.loopDepth, member.conditionalDepth)
      end
    end

    for _, call in source.calls do
      if call.expr.func.kind == 'ExprIndexName' and memberCallees[call.expr.func] == nil then continue end
      local depthCode, depthOverflow = depths:encode(call.functionDepth, call.loopDepth, call.conditionalDepth)
      local meta = 2 + depthCode * 4
      local row = refs.rows + 1
      refs:add {
        call.line,
        call.column,
        semanticSymbol(call.target, call.module),
        meta,
      }

      if depthOverflow then
        refDepthOverflow = depthOverflowAdd(refDepthOverflow, row, call.functionDepth, call.loopDepth, call.conditionalDepth)
      end
      callOnly += 1
    end

    for _, required in source.requires do
      local depthCode, depthOverflow = depths:encode(required.functionDepth, required.loopDepth, required.conditionalDepth)
      local meta = (if required.protected == true then 1 else 0) + depthCode * 2
      local row = requires.rows + 1
      local moduleId = moduleIntern(required.module)
      if moduleId >= U16Sentinel then error('compact module dictionary exceeded 16-bit identity space') end

      requires:add {
        storedRequireLine(required.line, row),
        moduleId,
        0,
        meta,
      }

      if depthOverflow then
        requireDepthOverflow = depthOverflowAdd(requireDepthOverflow, row, required.functionDepth, required.loopDepth, required.conditionalDepth)
      end
    end

    for _, count in { #source.calls, #source.members, #source.requires, #source.tables, #source.functions, #source.assignments } do
      if count >= U24Limit then error(`compact index: one source has {count} facts in a 24-bit count column`) end
    end

    sources:add {
      #text,
      math.min(#source.errors, 65535),
      refsStart,
      refs.rows - refsStart + 1,
      #source.calls,
      #source.members,
      requiresStart,
      #source.requires,
      #source.tables,
      #source.functions,
      #source.strings,
      #source.assignments,
    }
  end
  local lowerSeconds = os.clock() - started

  -- Local-require resolution is lowered once; suffix strings are deliberately temporary and never
  -- join the resident dictionaries. OpenMW defaults to case-insensitive module matching.
  local suffix = {}
  local caseInsensitive = given.caseInsensitiveModules == true
  for sourceId = 1, sources.rows do
    local normalized = analysis.normalizePath(sourcePath(sourceId))
    if caseInsensitive then normalized = string.lower(normalized) end
    local first = 1
    while true do
      local key = string.sub(normalized, first)
      local current = suffix[key]
      if current == nil then suffix[key] = sourceId elseif current ~= sourceId then suffix[key] = false end
      local slash = string.find(normalized, '/', first, true)
      if not slash then break end
      first = slash + 1
    end
  end

  local resolvedRequires = 0
  for sourceId = 1, sources.rows do
    local first = sources:get(sourceId, 7)
    local count = sources:get(sourceId, 8)
    for row = first, first + count - 1 do
      local moduleName = modulePool:resolve(requires:get(row, 2))
      if string.sub(moduleName, 1, 1) == '@' or string.find(moduleName, '^openmw%.') then continue end
      local candidate = string.gsub(moduleName, '%.', '/')
      if caseInsensitive then candidate = string.lower(candidate) end
      local target, ambiguous = nil, false
      for _, ending in { '.lua', '.luau', '/init.lua', '/init.luau' } do
        local value = suffix[candidate .. ending]
        if value == false then ambiguous = true; break end

        if type(value) == 'number' then
          if target and target ~= value then ambiguous = true; break end
          target = value
        end
      end

      if target and not ambiguous then requires:set(row, 3, target); resolvedRequires += 1 end
    end
  end
  suffix = nil

  depths:finishBuild()

  local function refDepths(row: number, meta: number): (number, number, number)
    local code = refDepthCode(meta)
    if code == 63 then
      local functionLevel, loopLevel, conditionalLevel = depthOverflowGet(refDepthOverflow, row)
      if functionLevel ~= nil and loopLevel ~= nil and conditionalLevel ~= nil then return functionLevel, loopLevel, conditionalLevel end
      return 0, 0, 0
    end
    return depths:decode(code)
  end

  local function requireDepths(row: number, meta: number): (number, number, number)
    local code = requireDepthCode(meta)
    if code == 63 then
      local functionLevel, loopLevel, conditionalLevel = depthOverflowGet(requireDepthOverflow, row)
      if functionLevel ~= nil and loopLevel ~= nil and conditionalLevel ~= nil then return functionLevel, loopLevel, conditionalLevel end
      return 0, 0, 0
    end
    return depths:decode(code)
  end

  local function sourceOf(row: number, startColumn: number, countColumn: number): number
    local low, high = 1, sources.rows
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local first = sources:get(middle, startColumn)
      local count = sources:get(middle, countColumn)
      if row < first then high = middle - 1
      elseif row >= first + count then low = middle + 1
      else return middle end
    end
    return 0
  end

  local sourceColumns = {
    'id', 'path', 'bytes', 'parse_errors', 'calls', 'members', 'requires',
    'tables', 'functions', 'strings', 'assignments',
  }

  local sourcePhysical = {
    bytes = 1, parse_errors = 2, calls = 5, members = 6, requires = 8,
    tables = 9, functions = 10, strings = 11, assignments = 12,
  }
  local sourceProvider = { columns = sourceColumns, indexes = { id = true } }

  local function safeLimit(request, handled: boolean): number?
    -- SQL LIMIT constrains result cardinality, not provider input cardinality. JessQL emits
    -- limitHint only for non-aggregate direct scans; honor it only when pushed WHERE is complete.
    if handled and request.whereComplete == true then return request.limitHint end
    return nil
  end

  local function sourceRow(sourceId: number, request)
    local row = {}
    for _, name in request.columns do
      if name == 'id' then row.id = sourceId
      elseif name == 'path' then row.path = sourcePath(sourceId)
      else
        local column = sourcePhysical[name]
        if column then row[name] = sources:get(sourceId, column) end
      end
    end
    return row
  end

  function sourceProvider.lookup(column, value, request)
    if column ~= 'id' or type(value) ~= 'number' or value < 1 or value > sources.rows then return {} end
    return { sourceRow(value, request) }
  end

  function sourceProvider.scan(request)
    local out = {}
    local limit = request.limitHint or request.limit
    local idEqual, pathEqual = nil, nil
    local handled = true
    for _, constraint in request.constraints do
      if constraint.op == '=' and constraint.column == 'id' then idEqual = constraint.value
      elseif constraint.op == '=' and constraint.column == 'path' then pathEqual = findSourcePath(constraint.value) or -1
      else handled = false end
    end

    local first, last = 1, sources.rows
    if type(idEqual) == 'number' then first, last = idEqual, idEqual end

    for sourceId = first, last do
      if sourceId >= 1 and sourceId <= sources.rows and (pathEqual == nil or sourceId == pathEqual) then
        table.insert(out, sourceRow(sourceId, request))
        if limit and #out >= limit then break end
      end
    end
    return { _jessqlScan = 'v1', rows = out, handledConstraints = handled }
  end

  function sourceProvider.iterate(request)
    local idEqual, pathEqual = nil, nil
    local handled = true
    for _, constraint in request.constraints do
      if constraint.op == '=' and constraint.column == 'id' then idEqual = constraint.value
      elseif constraint.op == '=' and constraint.column == 'path' then pathEqual = findSourcePath(constraint.value) or -1
      else handled = false end
    end
    local first, last = 1, sources.rows
    if type(idEqual) == 'number' then first, last = idEqual, idEqual end
    local sourceId = first - 1
    local emitted, limit = 0, safeLimit(request, handled)
    return {
      _jessqlIter = 'v1', handledConstraints = handled, handledWhere = false, ordered = false,
      next = function()
        while sourceId < last do
          if limit and emitted >= limit then return nil end
          sourceId += 1
          if sourceId >= 1 and sourceId <= sources.rows and (pathEqual == nil or sourceId == pathEqual) then
            emitted += 1
            return sourceRow(sourceId, request)
          end
        end
        return nil
      end,
    }
  end

  local refColumns = {
    'source_id', 'path', 'line', 'column', 'symbol_id', 'function_depth', 'loop_depth',
    'conditional_depth', 'target', 'module', 'member',
  }

  -- Built lazily: the resident source-major store is optimal for per-file inspection, while this
  -- 24-bit posting list makes semantic-symbol joins/index lookups cheap without duplicating rows.
  local symbolPostingStarts, symbolPostings = nil, nil
  local symbolPostingBytes = 0

  local function ensureSymbolPostings()
    if symbolPostingStarts then return end
    local symbolCount = symbolNodes.rows
    if refs.rows >= U24Limit then error('compact semantic reference table exceeded 24-bit row identity space') end
    local cursor = buffer.create((symbolCount + 1) * 3)
    local referenced = 0
    for rowId = 1, refs.rows do
      local symbol = refs:get(rowId, 3)
      if symbol ~= 0 then
        local offset = symbol * 3
        writeU24(cursor, offset, readU24(cursor, offset) + 1)
        referenced += 1
      end
    end

    local starts = buffer.create((symbolCount + 2) * 3)
    local nextOffset = 0
    for symbol = 1, symbolCount do
      local offset = symbol * 3
      writeU24(starts, offset, nextOffset)
      nextOffset += readU24(cursor, offset)
      writeU24(cursor, offset, readU24(starts, offset))
    end
    writeU24(starts, (symbolCount + 1) * 3, nextOffset)

    local postings = buffer.create(referenced * 3)
    for rowId = 1, refs.rows do
      local symbol = refs:get(rowId, 3)
      if symbol == 0 then continue end
      local cursorOffset = symbol * 3
      local offset = readU24(cursor, cursorOffset)
      writeU24(postings, offset * 3, rowId)
      writeU24(cursor, cursorOffset, offset + 1)
    end

    symbolPostingStarts = starts
    symbolPostings = postings
    symbolPostingBytes = buffer.len(starts) + buffer.len(postings)
  end

  local function referenceMatches(rowId: number, wantCall: boolean): boolean
    local kind = refKind(refs:get(rowId, 4))
    if wantCall then return kind == 2 or kind == 3 end
    return kind == 1 or kind == 3
  end

  local function projectReference(rowId: number, sourceId: number, request)
    local result = {}
    local meta, symbol, functionLevel, loopLevel, conditionalLevel = nil, nil, nil, nil, nil
    local function getSymbol(): number
      if symbol == nil then symbol = refs:get(rowId, 3) end
      return symbol
    end

    local function getDepths()
      if functionLevel == nil then
        if meta == nil then meta = refs:get(rowId, 4) end
        functionLevel, loopLevel, conditionalLevel = refDepths(rowId, meta)
      end
    end

    for _, name in request.columns do
      if name == 'source_id' then result.source_id = sourceId
      elseif name == 'path' then result.path = sourcePath(sourceId)
      elseif name == 'line' then result.line = refs:get(rowId, 1)
      elseif name == 'column' then result.column = refs:get(rowId, 2)
      elseif name == 'symbol_id' then result.symbol_id = getSymbol()
      elseif name == 'function_depth' then getDepths(); result.function_depth = functionLevel
      elseif name == 'loop_depth' then getDepths(); result.loop_depth = loopLevel
      elseif name == 'conditional_depth' then getDepths(); result.conditional_depth = conditionalLevel
      elseif name == 'target' then local value = getSymbol(); if value ~= 0 then result.target = symbolText(value) end
      elseif name == 'module' then
        local value = getSymbol()
        local moduleId = if value ~= 0 then symbolNodes:get(value, 3) else 0
        if moduleId ~= 0 then result.module = modulePool:resolve(moduleId) end
      elseif name == 'member' then
        local value = getSymbol()
        local moduleId = if value ~= 0 then symbolNodes:get(value, 3) else 0
        if moduleId ~= 0 then
          local target = symbolText(value)
          local moduleName = modulePool:resolve(moduleId)
          if target and string.sub(target, 1, #moduleName + 1) == moduleName .. '.' then
            result.member = string.sub(target, #moduleName + 2)
          end
        end
      end
    end
    return result
  end

  local function makeRefProvider(wantCall: boolean)
    local provider = {
      columns = refColumns,
      indexes = { source_id = true, symbol_id = true, target = true },
    }

    function provider.lookup(column, value, request)
      local out = {}
      local limit = request.limitHint or request.limit
      if column == 'source_id' and type(value) == 'number' and value >= 1 and value <= sources.rows then
        local first = sources:get(value, 3)
        local last = first + sources:get(value, 4) - 1
        for rowId = first, last do
          if referenceMatches(rowId, wantCall) then
            table.insert(out, projectReference(rowId, value, request))
            if limit and #out >= limit then break end
          end
        end
        return out
      end

      local symbol = if column == 'target' then findSymbol(value) else value
      if (column ~= 'symbol_id' and column ~= 'target') or type(symbol) ~= 'number'
        or symbol < 1 or symbol > symbolNodes.rows then return out end
      ensureSymbolPostings()
      local starts = symbolPostingStarts :: buffer
      local postings = symbolPostings :: buffer
      local first = readU24(starts, symbol * 3)
      local last = readU24(starts, (symbol + 1) * 3) - 1
      for offset = first, last do
        local rowId = readU24(postings, offset * 3)
        if not referenceMatches(rowId, wantCall) then continue end
        local sourceId = sourceOf(rowId, 3, 4)
        table.insert(out, projectReference(rowId, sourceId, request))
        if limit and #out >= limit then break end
      end
      return out
    end

    function provider.scan(request)
      local out = {}
      local limit = request.limitHint or request.limit
      local constraints, handled = {}, true
      local sourceEqual, symbolEqual = nil, nil
      for _, constraint in request.constraints do
        local rhs = constraint.value
        if constraint.column == 'target' and constraint.op == '=' then
          rhs = findSymbol(constraint.value) or -1
          symbolEqual = rhs
        elseif constraint.column == 'symbol_id' and constraint.op == '=' then symbolEqual = rhs
        elseif constraint.column == 'source_id' and constraint.op == '=' then sourceEqual = rhs
        elseif constraint.column == 'module' and constraint.op == '=' then rhs = modulePool:find(constraint.value) or -1
        elseif constraint.column ~= 'source_id' and constraint.column ~= 'symbol_id' and constraint.column ~= 'line' then handled = false end
        table.insert(constraints, { column = constraint.column, op = constraint.op, rhs = rhs })
      end

      if type(symbolEqual) == 'number' and symbolEqual > 0 and symbolEqual <= symbolNodes.rows then
        ensureSymbolPostings()
        local starts = symbolPostingStarts :: buffer
        local postings = symbolPostings :: buffer
        local first = readU24(starts, symbolEqual * 3)
        local last = readU24(starts, (symbolEqual + 1) * 3) - 1
        for offset = first, last do
          local rowId = readU24(postings, offset * 3)
          if not referenceMatches(rowId, wantCall) then continue end
          local sourceId = sourceOf(rowId, 3, 4)
          if sourceEqual == nil or sourceId == sourceEqual then
            table.insert(out, projectReference(rowId, sourceId, request))
            if limit and #out >= limit then break end
          end
        end
        return { _jessqlScan = 'v1', rows = out, handledConstraints = handled }
      end

      local sourceId = if type(sourceEqual) == 'number' then sourceEqual else 1
      local firstRow, lastRow = 1, refs.rows
      if type(sourceEqual) == 'number' then
        if sourceEqual < 1 or sourceEqual > sources.rows then
          return { _jessqlScan = 'v1', rows = out, handledConstraints = handled }
        end
        firstRow = sources:get(sourceEqual, 3)
        lastRow = firstRow + sources:get(sourceEqual, 4) - 1
      end

      local nextEnd = if sourceId <= sources.rows then sources:get(sourceId, 3) + sources:get(sourceId, 4) else firstRow
      for rowId = firstRow, lastRow do
        while sourceId <= sources.rows and rowId >= nextEnd do
          sourceId += 1
          if sourceId <= sources.rows then nextEnd = sources:get(sourceId, 3) + sources:get(sourceId, 4) end
        end

        if not referenceMatches(rowId, wantCall) then continue end
        local symbol = refs:get(rowId, 3)
        local hit = true
        for _, constraint in constraints do
          local value = nil
          if constraint.column == 'source_id' then value = sourceId
          elseif constraint.column == 'symbol_id' or constraint.column == 'target' then value = symbol
          elseif constraint.column == 'module' then value = if symbol ~= 0 then symbolNodes:get(symbol, 3) else 0
          elseif constraint.column == 'line' then value = refs:get(rowId, 1)
          else continue end

          local ok = if constraint.op == '=' then value == constraint.rhs
            elseif constraint.op == '!=' or constraint.op == '<>' then value ~= constraint.rhs
            elseif constraint.op == '<' then value < constraint.rhs
            elseif constraint.op == '<=' then value <= constraint.rhs
            elseif constraint.op == '>' then value > constraint.rhs
            elseif constraint.op == '>=' then value >= constraint.rhs
            else true
          if not ok then hit = false; break end
        end

        if hit then
          table.insert(out, projectReference(rowId, sourceId, request))
          if limit and #out >= limit then break end
        end
      end
      return { _jessqlScan = 'v1', rows = out, handledConstraints = handled }
    end

    function provider.iterate(request)
      local constraints, handled = {}, true
      local sourceEqual, symbolEqual = nil, nil
      for _, constraint in request.constraints do
        local rhs = constraint.value
        if constraint.column == 'target' and constraint.op == '=' then
          rhs = findSymbol(constraint.value) or -1
          symbolEqual = rhs
        elseif constraint.column == 'symbol_id' and constraint.op == '=' then symbolEqual = rhs
        elseif constraint.column == 'source_id' and constraint.op == '=' then sourceEqual = rhs
        elseif constraint.column == 'module' and constraint.op == '=' then rhs = modulePool:find(constraint.value) or -1
        elseif constraint.column ~= 'source_id' and constraint.column ~= 'symbol_id' and constraint.column ~= 'line' then handled = false end
        constraints[#constraints + 1] = { column = constraint.column, op = constraint.op, rhs = rhs }
      end

      local emitted, limit = 0, safeLimit(request, handled)
      local postingOffset, postingLast = nil, nil
      local sourceId = if type(sourceEqual) == 'number' then sourceEqual else 1
      local rowId, lastRow = 1, refs.rows
      local nextEnd = if sourceId <= sources.rows then sources:get(sourceId, 3) + sources:get(sourceId, 4) else 1

      if type(symbolEqual) == 'number' and symbolEqual > 0 and symbolEqual <= symbolNodes.rows then
        ensureSymbolPostings()
        local starts = symbolPostingStarts :: buffer
        postingOffset = readU24(starts, symbolEqual * 3)
        postingLast = readU24(starts, (symbolEqual + 1) * 3) - 1
      elseif type(sourceEqual) == 'number' then
        if sourceEqual < 1 or sourceEqual > sources.rows then rowId, lastRow = 1, 0
        else
          rowId = sources:get(sourceEqual, 3)
          lastRow = rowId + sources:get(sourceEqual, 4) - 1
          nextEnd = lastRow + 1
        end
      end

      local function matches(row: number, source: number): boolean
        if not referenceMatches(row, wantCall) then return false end
        local symbol = refs:get(row, 3)
        for _, constraint in constraints do
          local value = nil
          if constraint.column == 'source_id' then value = source
          elseif constraint.column == 'symbol_id' or constraint.column == 'target' then value = symbol
          elseif constraint.column == 'module' then value = if symbol ~= 0 then symbolNodes:get(symbol, 3) else 0
          elseif constraint.column == 'line' then value = refs:get(row, 1)
          else continue end
          local ok = if constraint.op == '=' then value == constraint.rhs
            elseif constraint.op == '!=' or constraint.op == '<>' then value ~= constraint.rhs
            elseif constraint.op == '<' then value < constraint.rhs
            elseif constraint.op == '<=' then value <= constraint.rhs
            elseif constraint.op == '>' then value > constraint.rhs
            elseif constraint.op == '>=' then value >= constraint.rhs
            else true
          if not ok then return false end
        end
        return true
      end

      return {
        _jessqlIter = 'v1', handledConstraints = handled, handledWhere = false, ordered = false,
        next = function()
          while true do
            if limit and emitted >= limit then return nil end
            local current, currentSource
            if postingOffset ~= nil then
              if postingLast == nil or postingOffset > postingLast then return nil end
              local postings = symbolPostings :: buffer
              current = readU24(postings, postingOffset * 3)
              postingOffset += 1
              currentSource = sourceOf(current, 3, 4)
              if sourceEqual ~= nil and currentSource ~= sourceEqual then continue end
            else
              if rowId > lastRow then return nil end
              current = rowId
              rowId += 1
              if sourceEqual ~= nil then currentSource = sourceEqual
              else
                while sourceId <= sources.rows and current >= nextEnd do
                  sourceId += 1
                  if sourceId <= sources.rows then nextEnd = sources:get(sourceId, 3) + sources:get(sourceId, 4) end
                end
                currentSource = sourceId
              end
            end

            if matches(current, currentSource) then
              emitted += 1
              return projectReference(current, currentSource, request)
            end
          end
        end,
      }
    end
    return provider
  end

  local requireColumns = {
    'source_id', 'line', 'module_id', 'module', 'target_source_id', 'protected',
    'function_depth', 'loop_depth', 'conditional_depth',
  }
  local requireProvider = { columns = requireColumns }
  function requireProvider.scan(request)
    local out = {}
    local limit = request.limitHint or request.limit
    local constraints, handled = {}, true
    for _, constraint in request.constraints do
      local rhs = constraint.value
      if constraint.column == 'module' and constraint.op == '=' then rhs = modulePool:find(constraint.value) or -1
      elseif constraint.column ~= 'source_id' and constraint.column ~= 'module_id' and constraint.column ~= 'target_source_id' then handled = false end
      table.insert(constraints, { column = constraint.column, op = constraint.op, rhs = rhs })
    end

    local sourceId = 1
    local nextEnd = if sources.rows > 0 then sources:get(1, 7) + sources:get(1, 8) else 1
    for rowId = 1, requires.rows do
      while sourceId <= sources.rows and rowId >= nextEnd do
        sourceId += 1
        if sourceId <= sources.rows then nextEnd = sources:get(sourceId, 7) + sources:get(sourceId, 8) end
      end

      local moduleId = requires:get(rowId, 2)
      local hit = true
      for _, constraint in constraints do
        local value = if constraint.column == 'source_id' then sourceId
          elseif constraint.column == 'module' or constraint.column == 'module_id' then moduleId
          elseif constraint.column == 'target_source_id' then requires:get(rowId, 3)
          else nil
        if value == nil then continue end
        local ok = if constraint.op == '=' then value == constraint.rhs
          elseif constraint.op == '!=' or constraint.op == '<>' then value ~= constraint.rhs
          elseif constraint.op == '<' then value < constraint.rhs
          elseif constraint.op == '<=' then value <= constraint.rhs
          elseif constraint.op == '>' then value > constraint.rhs
          elseif constraint.op == '>=' then value >= constraint.rhs
          else true
        if not ok then hit = false; break end
      end

      if not hit then continue end

      local meta = requires:get(rowId, 4)
      local functionLevel, loopLevel, conditionalLevel = requireDepths(rowId, meta)
      local result = {}
      for _, name in request.columns do
        if name == 'source_id' then result.source_id = sourceId
        elseif name == 'line' then result.line = requireLine(rowId)
        elseif name == 'module_id' then result.module_id = moduleId
        elseif name == 'module' then result.module = modulePool:resolve(moduleId)
        elseif name == 'target_source_id' then result.target_source_id = requires:get(rowId, 3)
        elseif name == 'protected' then result.protected = protectedRequire(meta)
        elseif name == 'function_depth' then result.function_depth = functionLevel
        elseif name == 'loop_depth' then result.loop_depth = loopLevel
        elseif name == 'conditional_depth' then result.conditional_depth = conditionalLevel end
      end
      table.insert(out, result)
      if limit and #out >= limit then break end
    end
    return { _jessqlScan = 'v1', rows = out, handledConstraints = handled }
  end

  function requireProvider.iterate(request)
    local constraints, handled, sourceEqual = {}, true, nil
    for _, constraint in request.constraints do
      local rhs = constraint.value
      if constraint.column == 'module' and constraint.op == '=' then rhs = modulePool:find(constraint.value) or -1
      elseif constraint.column ~= 'source_id' and constraint.column ~= 'module_id' and constraint.column ~= 'target_source_id' then handled = false end

      if constraint.column == 'source_id' and constraint.op == '=' then sourceEqual = rhs end
      constraints[#constraints + 1] = { column = constraint.column, op = constraint.op, rhs = rhs }
    end

    local sourceId = if type(sourceEqual) == 'number' then sourceEqual else 1
    local rowId, lastRow = 1, requires.rows
    local nextEnd = if sourceId <= sources.rows then sources:get(sourceId, 7) + sources:get(sourceId, 8) else 1
    if type(sourceEqual) == 'number' then
      if sourceEqual < 1 or sourceEqual > sources.rows then rowId, lastRow = 1, 0
      else
        rowId = sources:get(sourceEqual, 7)
        lastRow = rowId + sources:get(sourceEqual, 8) - 1
        nextEnd = lastRow + 1
      end
    end
    local emitted, limit = 0, safeLimit(request, handled)

    return {
      _jessqlIter = 'v1', handledConstraints = handled, handledWhere = false, ordered = false,
      next = function()
        while rowId <= lastRow do
          if limit and emitted >= limit then return nil end
          local current = rowId
          rowId += 1
          if sourceEqual == nil then
            while sourceId <= sources.rows and current >= nextEnd do
              sourceId += 1
              if sourceId <= sources.rows then nextEnd = sources:get(sourceId, 7) + sources:get(sourceId, 8) end
            end
          end
          local moduleId = requires:get(current, 2)
          local hit = true
          for _, constraint in constraints do
            local value = if constraint.column == 'source_id' then sourceId
              elseif constraint.column == 'module' or constraint.column == 'module_id' then moduleId
              elseif constraint.column == 'target_source_id' then requires:get(current, 3)
              else nil
            if value ~= nil then
              local ok = if constraint.op == '=' then value == constraint.rhs
                elseif constraint.op == '!=' or constraint.op == '<>' then value ~= constraint.rhs
                elseif constraint.op == '<' then value < constraint.rhs
                elseif constraint.op == '<=' then value <= constraint.rhs
                elseif constraint.op == '>' then value > constraint.rhs
                elseif constraint.op == '>=' then value >= constraint.rhs
                else true
              if not ok then hit = false; break end
            end
          end

          if not hit then continue end

          local meta = requires:get(current, 4)
          local functionLevel, loopLevel, conditionalLevel = requireDepths(current, meta)
          local result = {}
          for _, name in request.columns do
            if name == 'source_id' then result.source_id = sourceId
            elseif name == 'line' then result.line = requireLine(current)
            elseif name == 'module_id' then result.module_id = moduleId
            elseif name == 'module' then result.module = modulePool:resolve(moduleId)
            elseif name == 'target_source_id' then result.target_source_id = requires:get(current, 3)
            elseif name == 'protected' then result.protected = protectedRequire(meta)
            elseif name == 'function_depth' then result.function_depth = functionLevel
            elseif name == 'loop_depth' then result.loop_depth = loopLevel
            elseif name == 'conditional_depth' then result.conditional_depth = conditionalLevel end
          end
          emitted += 1
          return result
        end
        return nil
      end,
    }
  end

  -- Aggregate semantic usage is itself useful index data. Keep three 24-bit counters per symbol
  -- and expose them as an ordered provider so SQL can answer top-k questions without decoding and
  -- grouping 1.6M reference rows into Lua objects.
  local symbolUsage = nil
  local symbolUsageBytes = 0
  local function ensureSymbolUsage()
    if symbolUsage then return end
    local symbolCount = symbolNodes.rows
    local counts = buffer.create((symbolCount + 1) * 9)
    for rowId = 1, refs.rows do
      local symbol = refs:get(rowId, 3)
      local offset = symbol * 9
      local references = readU24(counts, offset)
      if references >= U24Limit - 1 then error('compact symbol reference count exceeded 24-bit range') end
      writeU24(counts, offset, references + 1)

      local kind = refKind(refs:get(rowId, 4))
      if kind == 1 or kind == 3 then
        local members = readU24(counts, offset + 3)
        if members >= U24Limit - 1 then error('compact symbol member count exceeded 24-bit range') end
        writeU24(counts, offset + 3, members + 1)
      end

      if kind == 2 or kind == 3 then
        local calls = readU24(counts, offset + 6)
        if calls >= U24Limit - 1 then error('compact symbol call count exceeded 24-bit range') end
        writeU24(counts, offset + 6, calls + 1)
      end
    end
    symbolUsage = counts
    symbolUsageBytes = buffer.len(counts)
  end

  local function usageValue(symbolId: number, column: string): number
    ensureSymbolUsage()
    local counts = symbolUsage :: buffer
    local offset = symbolId * 9
    if column == 'references' then return readU24(counts, offset) end
    if column == 'members' then return readU24(counts, offset + 3) end
    if column == 'calls' then return readU24(counts, offset + 6) end
    return symbolId
  end

  local usageColumns = { 'symbol_id', 'references', 'members', 'calls' }
  local usageProvider = { columns = usageColumns }
  local function usageRow(symbolId: number, request)
    local row = {}
    for _, name in request.columns do
      if name == 'symbol_id' then row.symbol_id = symbolId
      elseif name == 'references' or name == 'members' or name == 'calls' then row[name] = usageValue(symbolId, name) end
    end
    return row
  end

  local function usageConstraintMatches(symbolId: number, constraints): boolean
    for _, constraint in constraints do
      local value = if constraint.column == 'symbol_id' then symbolId else usageValue(symbolId, constraint.column)
      local rhs = constraint.value
      local ok = if constraint.op == '=' then value == rhs
        elseif constraint.op == '!=' or constraint.op == '<>' then value ~= rhs
        elseif constraint.op == '<' then value < rhs
        elseif constraint.op == '<=' then value <= rhs
        elseif constraint.op == '>' then value > rhs
        elseif constraint.op == '>=' then value >= rhs
        else true
      if not ok then return false end
    end
    return true
  end

  local function usageTopIds(column: string, desc: boolean, limit: number, constraints): { number }
    if limit <= 0 then return {} end
    local heap = table.create(limit)
    local function before(left: number, right: number): boolean
      local leftValue, rightValue = usageValue(left, column), usageValue(right, column)
      if leftValue == rightValue then return left < right end
      if desc then return leftValue > rightValue end
      return leftValue < rightValue
    end

    local function worse(left: number, right: number): boolean return before(right, left) end

    local function siftUp(index: number)
      while index > 1 do
        local parent = math.floor(index / 2)
        if not worse(heap[index], heap[parent]) then break end
        heap[index], heap[parent] = heap[parent], heap[index]
        index = parent
      end
    end

    local function siftDown(index: number)
      while true do
        local left = index * 2
        if left > #heap then return end
        local right = left + 1
        local worst = left
        if right <= #heap and worse(heap[right], heap[left]) then worst = right end
        if not worse(heap[worst], heap[index]) then return end
        heap[index], heap[worst] = heap[worst], heap[index]
        index = worst
      end
    end

    for symbolId = 0, symbolNodes.rows do
      if not usageConstraintMatches(symbolId, constraints) then continue end

      if #heap < limit then
        heap[#heap + 1] = symbolId
        siftUp(#heap)
      elseif before(symbolId, heap[1]) then
        heap[1] = symbolId
        siftDown(1)
      end
    end
    table.sort(heap, before)
    return heap
  end

  function usageProvider.iterate(request)
    ensureSymbolUsage()
    local constraints = request.constraints or {}
    local orderedIds = nil
    local orderBy = request.orderBy
    if orderBy and #orderBy == 1 and request.limitHint then
      local order = orderBy[1]
      if order.column == 'references' or order.column == 'members' or order.column == 'calls' then
        orderedIds = usageTopIds(order.column, order.desc == true, request.limitHint, constraints)
      end
    end

    local position = 0
    local symbolId = -1
    return {
      _jessqlIter = 'v1',
      handledConstraints = true,
      handledWhere = false,
      ordered = orderedIds ~= nil,
      next = function()
        if orderedIds then
          position += 1
          local id = orderedIds[position]
          if id == nil then return nil end
          return usageRow(id, request)
        end

        while symbolId < symbolNodes.rows do
          symbolId += 1
          if usageConstraintMatches(symbolId, constraints) then return usageRow(symbolId, request) end
        end
        return nil
      end,
    }
  end

  function usageProvider.scan(request)
    local iter = usageProvider.iterate(request)
    local rows = {}
    local limit = request.limitHint or request.limit
    while true do
      local row = iter.next()
      if row == nil then break end
      rows[#rows + 1] = row
      if limit and #rows >= limit then break end
    end
    return { _jessqlScan = 'v1', rows = rows, handledConstraints = true, ordered = iter.ordered }
  end

  local symbolProvider = { columns = { 'id', 'target', 'module', 'member' }, indexes = { id = true, target = true } }
  local function symbolRow(id: number, request)
    local result = {}
    local moduleId = symbolNodes:get(id, 3)
    for _, name in request.columns do
      if name == 'id' then result.id = id
      elseif name == 'target' then result.target = symbolText(id)
      elseif name == 'module' then if moduleId ~= 0 then result.module = modulePool:resolve(moduleId) end
      elseif name == 'member' and moduleId ~= 0 then
        local target = symbolText(id)
        local moduleName = modulePool:resolve(moduleId)
        if target and string.sub(target, 1, #moduleName + 1) == moduleName .. '.' then
          result.member = string.sub(target, #moduleName + 2)
        end
      end
    end
    return result
  end

  function symbolProvider.lookup(column, value, request)
    local id = if column == 'target' then findSymbol(value) else value
    if (column ~= 'id' and column ~= 'target') or type(id) ~= 'number' or id < 1 or id > symbolNodes.rows then return {} end
    return { symbolRow(id, request) }
  end

  function symbolProvider.scan(request)
    local out = {}
    local limit = request.limitHint or request.limit
    local idEqual, handled = nil, true
    for _, constraint in request.constraints do
      if constraint.op == '=' and constraint.column == 'id' then idEqual = constraint.value
      elseif constraint.op == '=' and constraint.column == 'target' then idEqual = findSymbol(constraint.value) or -1
      else handled = false end
    end
    local first, last = 1, symbolNodes.rows
    if type(idEqual) == 'number' then first, last = idEqual, idEqual end

    for id = first, last do
      if id >= 1 and id <= symbolNodes.rows then
        table.insert(out, symbolRow(id, request))
        if limit and #out >= limit then break end
      end
    end
    return { _jessqlScan = 'v1', rows = out, handledConstraints = handled }
  end

  function symbolProvider.iterate(request)
    local idEqual, handled = nil, true
    for _, constraint in request.constraints do
      if constraint.op == '=' and constraint.column == 'id' then idEqual = constraint.value
      elseif constraint.op == '=' and constraint.column == 'target' then idEqual = findSymbol(constraint.value) or -1
      else handled = false end
    end
    local first, last = 1, symbolNodes.rows
    if type(idEqual) == 'number' then first, last = idEqual, idEqual end
    local id = first - 1
    local emitted, limit = 0, safeLimit(request, handled)
    return {
      _jessqlIter = 'v1', handledConstraints = handled, handledWhere = false, ordered = false,
      next = function()
        while id < last do
          if limit and emitted >= limit then return nil end
          id += 1
          if id >= 1 and id <= symbolNodes.rows then emitted += 1; return symbolRow(id, request) end
        end
        return nil
      end,
    }
  end

  local db = sql.new()
  db:register('sources', sourceProvider)
  db:register('calls', makeRefProvider(true))
  db:register('members', makeRefProvider(false))
  db:register('requires', requireProvider)
  db:register('symbols', symbolProvider)
  db:register('symbol_usage', usageProvider)

  local overflowBytes = refs:overflowBytes()
    + (if refDepthOverflow then refDepthOverflow:bytes() else 0)
    + (if requireLineOverflow then requireLineOverflow:bytes() else 0)
    + (if requireDepthOverflow then requireDepthOverflow:bytes() else 0)
  local depthBytes = depths.triples:bytes()
  local packedBytes = sources:bytes() + refs:bytes() + requires:bytes()
    + symbolNodes:bytes() + symbolNodes:overflowBytes() + depthBytes + overflowBytes
  local edgeBytes = buffer.len(edgeSlots)
  local pathBytes = pathAtomPool:memory() + pathNodes:bytes() + sourceByPathNode:bytes()
    + sourcePathLeaf:bytes() + sourceRoot:bytes() + buffer.len(pathEdgeSlots)
  local internBytes = modulePool:memory() + atomPool:memory() + pathAtomPool:memory()
  local nativeBytes = packedBytes + internBytes + edgeBytes
    + pathNodes:bytes() + sourceByPathNode:bytes() + sourcePathLeaf:bytes() + sourceRoot:bytes() + buffer.len(pathEdgeSlots)

  local stats = table.freeze {
    sources = sources.rows,
    sourceBytes = totalBytes,
    calls = (function() local count = 0; for id = 1, sources.rows do count += sources:get(id, 5) end; return count end)(),
    members = (function() local count = 0; for id = 1, sources.rows do count += sources:get(id, 6) end; return count end)(),
    references = refs.rows,
    requires = requires.rows,
    symbols = symbolNodes.rows,
    modules = modulePool:count(),
    atoms = atomPool:count(),
    resolvedRequires = resolvedRequires,
    mergedCallMembers = duplicatedCallMembers,
    callOnlyReferences = callOnly,
    lowerSeconds = lowerSeconds,
    nativeBytes = nativeBytes,
    packedBytes = packedBytes,
    internBytes = internBytes,
    overflowBytes = overflowBytes,
    depthBytes = depthBytes,
    depthCodes = depths.triples.rows,
    symbolOverflowBytes = symbolNodes:overflowBytes(),
    pathBytes = pathBytes,
    pathAtomBytes = pathAtomPool:memory(),
    pathNodeBytes = pathNodes:bytes() + sourceByPathNode:bytes() + sourcePathLeaf:bytes() + sourceRoot:bytes(),
    pathEdgeBytes = buffer.len(pathEdgeSlots),
    moduleBytes = modulePool:memory(),
    atomBytes = atomPool:memory(),
    edgeBytes = edgeBytes,
    postingBytes = function() return symbolPostingBytes end,
    usageBytes = function() return symbolUsageBytes end,
    rowBytes = table.freeze { source = sources.rowWidth, reference = refs.rowWidth, require = requires.rowWidth },
  }

  local index = { db = db, stats = stats }
  function index:query(statement: string, params)
    return self.db:query(statement, params)
  end

  function index:prepare(statement: string)
    return self.db:prepare(statement)
  end

  function index:path(sourceId: number): string
    return sourcePath(sourceId)
  end

  function index:symbol(symbolId: number): string?
    return symbolText(symbolId)
  end

  function index:module(moduleId: number): string
    return modulePool:resolve(moduleId)
  end

  function index:sourceOfCallRow(row: number): number
    return sourceOf(row, 3, 4)
  end

  function index:sourceOfRequireRow(row: number): number
    return sourceOf(row, 7, 8)
  end

  return index
end

return table.freeze { build = build }
