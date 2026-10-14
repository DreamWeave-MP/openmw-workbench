--!strict
--!native
local style = require '@jess/style'
local model = require '@openmw/workbench/model'
local review = require '@openmw/workbench/review'
local graph = require '@openmw/workbench/graph'
local content = require '@openmw/workbench/content'
local knowledge = require '@openmw/workbench/knowledge'
local link = require '@openmw/workbench/link'
local compact = require '@openmw/workbench/compact'


local function index(paths: { string } | string, options)
  local given = if options then table.clone(options) else {}
  if given.transform == nil then given.transform = model.normalizeLuaDialect end
  if given.caseInsensitiveModules == nil then given.caseInsensitiveModules = true end
  return compact.build(paths, given)
end

local function open(paths: { string } | string)
  local roots = if type(paths) == 'string' then { paths :: string } else paths
  return model.build(roots)
end

local function inspect(paths: { string } | string, options)
  local given = options or {}
  local project = open(paths)
  local linked = if given.content then link.build(project) else nil
  local reportOptions = table.clone(given)
  reportOptions.linked = linked
  local report = review.review(project, reportOptions)
  return {
    project = project,
    report = report,
    linked = linked,
    graph = graph.build(project, linked),
  }
end

local function printReport(report)
  print(`OpenMW Workbench [{report.profile}]`)
  print(`scripts={report.summary.scripts} manifests={report.summary.manifests} contentConfigs={report.summary.contentConfigs} errors={report.summary.errors} warnings={report.summary.warnings} notes={report.summary.notes}`)
  for _, item in report.findings do print(review.format(item)) end
end

return table.freeze {
  open = open,
  inspect = inspect,
  review = review.review,
  graph = graph.build,
  printReport = printReport,
  formatFinding = review.format,
  knowledge = knowledge,
  content = content,
  link = link.build,
  linker = link,
  compact = compact,
  index = index,
  style = style,
}
