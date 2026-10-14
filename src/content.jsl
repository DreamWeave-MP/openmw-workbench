--!strict
--!native
-- Data-world adapters over the standalone tes3, vfs, nif and tes3-saves packages. The source
-- analyzer remains independent of these modules; the full workbench layer activates them so
-- source, content, VFS and NIF facts can be correlated.
local tes3 = require '@tes3'
local vfs = require '@vfs'
local nif = require '@nif'
local saves = require '@tes3-saves'

export type StringField = tes3.StringField

local function readBuffer(path: string)
  local bytes = jess.fs.readBuffer(path)
  if not bytes then error(`{path}: no such file`) end
  return bytes
end

local function openPlugin(path: string)
  return tes3.open(readBuffer(path))
end

local function openNif(path: string)
  return nif.open(readBuffer(path))
end

-- OpenMW stores embedded Lua configuration in a single LUAL record inside
-- .omwaddon/.omwgame content files. The tes3 package already knows the TES3
-- record layout, so expose the decoded ScriptConfigList instead of duplicating
-- that binary format in the workbench.
local function scriptConfig(path: string)
  local plugin = openPlugin(path)
  local index = tes3.records.find(plugin, 'LUAL')
  if index == nil then return {} end

  local decoded = tes3.display.display(plugin, index)
  if type(decoded) ~= 'table' or decoded.type ~= 'ScriptConfigList' or type(decoded.scripts) ~= 'table' then
    return {}
  end
  return decoded.scripts
end

return table.freeze {
  tes3 = tes3,
  vfs = vfs,
  nif = nif,
  saves = saves,
  openPlugin = openPlugin,
  openNif = openNif,
  scriptConfig = scriptConfig,
}
