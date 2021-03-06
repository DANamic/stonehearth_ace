local log = radiant.log.create_logger('item_io_lib')

local item_io_lib = {}

function item_io_lib._rank_inputs(inputs)
   local ranked_inputs = {}
   for _, input in pairs(inputs or {}) do
      local input_comp = input:is_valid() and input:get_component('stonehearth_ace:input')
      if input_comp then
         table.insert(ranked_inputs, input_comp)
      end
   end

   -- sort the inputs by priority
   if #ranked_inputs > 0 then
      table.sort(ranked_inputs, function(a, b)
         return a:get_priority() > b:get_priority()
      end)
   end

   return ranked_inputs
end

function item_io_lib.try_output(items, inputs, options)
   local spills = {}
   local successes = {}
   local fails = {}
   options = options or {}

   local ranked_inputs = item_io_lib._rank_inputs(inputs)
   item_io_lib._output_to_inputs(items, ranked_inputs, successes, fails)
   
   local prev_outputs = {}
   local output = options.output
   while output do
      -- don't need to (continue) process(ing) through outputs if there are no (more) fails
      if not next(fails) then
         break
      end
      if prev_outputs[output] then
         break
      end
      local output_comp = output:get_component('stonehearth_ace:output')
      if not output_comp then
         break
      end

      prev_outputs[output] = true

      ranked_inputs = item_io_lib._rank_inputs(output_comp:get_inputs())
      if #ranked_inputs > 0 then
         items = fails
         fails = {}
         item_io_lib._output_to_inputs(items, ranked_inputs, successes, fails)
      end
      
      output = output_comp:get_parent_output()
   end

   if options.spill_fail_items then
      local origin = options.spill_origin
      local min_radius = options.spill_min_radius
      local max_radius = options.spill_max_radius

      for id, item in pairs(fails) do
         local location = radiant.terrain.find_placement_point(origin, min_radius, max_radius)
         radiant.terrain.place_entity(item, location)
         spills[id] = item
         fails[id] = nil
      end
   elseif options.delete_fail_items ~= false then  -- do this unless otherwise specified so we don't have entities in the void
      for id, item in pairs(fails) do
         radiant.entities.destroy_entity(item)
         fails[id] = nil
      end
   end

   return {
      spilled = spills,
      succeeded = successes,
      failed = fails
   }
end

function item_io_lib._output_to_inputs(items, inputs, successes, fails)
   for id, item in pairs(items) do
      for _, input in ipairs(inputs) do
         if input:try_input(item) then
            successes[id] = item
            break
         end
      end

      if not successes[id] then
         fails[id] = item
      end
   end
end

-- determines if items simply *can* be output to their respective destinations
-- ignores spill settings, because if spill is allowed then of course the items can be output
-- if reservations obtained for all items, returns function to perform the output
-- otherwise, destroys any successful reservations and returns false
function item_io_lib.can_output(items, inputs, options)
   local successes = {}
   local fails = {}
   options = options or {}

   local ranked_inputs = item_io_lib._rank_inputs(inputs)
   item_io_lib._can_output_to_inputs(items, ranked_inputs, successes, fails)
   
   local prev_outputs = {}
   local output = options.output
   while output do
      -- don't need to (continue) process(ing) through outputs if there are no (more) fails
      if not next(fails) then
         break
      end
      if prev_outputs[output] then
         break
      end
      local output_comp = output:get_component('stonehearth_ace:output')
      if not output_comp then
         break
      end

      prev_outputs[output] = true

      ranked_inputs = item_io_lib._rank_inputs(output_comp:get_inputs())
      if #ranked_inputs > 0 then
         items = fails
         fails = {}
         item_io_lib._can_output_to_inputs(items, ranked_inputs, successes, fails)
      end
      
      output = output_comp:get_parent_output()
   end

   if next(fails) then
      -- release all reserved spaces
      for id, reservation in pairs(successes) do
         reservation.destroy()
      end
      return false
   end

   return function()
      --log:debug('trying to output %s', radiant.util.table_tostring(items))
      for id, success in pairs(successes) do
         success.output()
      end
   end
end

function item_io_lib._can_output_to_inputs(items, inputs, successes, fails)
   for id, item in pairs(items) do
      for _, input in ipairs(inputs) do
         local result = input:can_input(item)
         if result then
            successes[id] = {
               output = function()
                  --log:debug('trying to push %s into %s', item, input._entity)
                  -- first destroy the space reservation
                  result.destroy()
                  -- then force input the item
                  input:try_input(item, true)
               end
            }
            break
         end
      end

      if not successes[id] then
         fails[id] = item
      end
   end
end

return item_io_lib
