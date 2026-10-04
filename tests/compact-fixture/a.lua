local ui = require('openmw.ui')
local helper = require('tests.compact-fixture.b')
local create = ui.create
return function(layout)
  helper()
  return create(layout)
end
