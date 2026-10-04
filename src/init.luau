--!strict
--!native
local style = require '@jess/style'
local model = require '@openmw/workbench/model'
local review = require '@openmw/workbench/review'
local graph = require '@openmw/workbench/graph'
local content = require '@openmw/workbench/content'
local knowledge = require '@openmw/workbench/knowledge'

local function open(paths: { string } | string)
  local roots = if type(paths) == 'string' then { paths :: string } else paths
  return model.build(roots)
end

local function inspect(paths: { string } | string, options)
  local project = open(paths)
  local report = review.review(project, options)
  return {
    project = project,
    report = report,
    graph = graph.build(project),
  }
end

local function printReport(report)
  print(`OpenMW Workbench [{report.profile}]`)
  print(`scripts={report.summary.scripts} manifests={report.summary.manifests} errors={report.summary.errors} warnings={report.summary.warnings} notes={report.summary.notes}`)
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
  style = style,
}
