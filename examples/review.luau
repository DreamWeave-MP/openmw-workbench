--!strict
-- Run with the workbench package activated after builtin.jpk and dreamwind.jpk are available.
local workbench = require '@openmw/workbench'
local roots = {}
for index = 1, #arg do table.insert(roots, arg[index]) end
if #roots == 0 then roots = { '.' } end
local project = workbench.open(roots)
local report = workbench.review(project, { profile = 'default' })
workbench.printReport(report)
