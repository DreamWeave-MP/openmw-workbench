--!strict
--!native
-- Dreamwind-backed data-world adapters. The source analyzer remains independent of these modules;
-- the full workbench layer activates them so source, content, VFS and NIF facts can be correlated.
local tes3 = require '@dreamwind/tes3'
local vfs = require '@dreamwind/vfs'
local nif = require '@dreamwind/nif'
local saves = require '@dreamwind/saves'

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

return table.freeze {
  tes3 = tes3,
  vfs = vfs,
  nif = nif,
  saves = saves,
  openPlugin = openPlugin,
  openNif = openNif,
}
