local Point3 = _radiant.csg.Point3
local Region3 = _radiant.csg.Region3
local log = radiant.log.create_logger('farmer_field')
local FarmerFieldComponent = require 'stonehearth.components.farmer_field.farmer_field_component'

local AceFarmerFieldComponent = class()

local RECALCULATE_THRESHOLD = 0.5

AceFarmerFieldComponent._old_restore = FarmerFieldComponent.restore
function AceFarmerFieldComponent:restore()
   self._is_restore = true
   
   self:_old_restore()

   -- if this is an old farm that doesn't have full details, reload the details
   if self._sv.current_crop_details and not self._sv.current_crop_details.flood_period_multiplier then
      self._sv.current_crop_details = stonehearth.farming:get_crop_details(self._sv.current_crop_alias)
      self.__saved_variables:mark_changed()
   end

   self:_cache_best_water_level()
end

function AceFarmerFieldComponent:post_activate()
   self._flood_listeners = {}
   
   if self._is_restore then
      self:_create_water_listener()
      self:_create_flood_listeners()
   end

   self:_ensure_crop_counts()
   self:_ensure_fertilize_layer()
   self:_ensure_fertilizer_preference()
end

function AceFarmerFieldComponent:_ensure_crop_counts()
   -- make sure we're properly tracking fertilized counts and flooded counts
   if not self._sv.num_fertilized then
      local num_fertilized = 0
      for x=1, self._sv.size.x do
         for y=1, self._sv.size.y do
            local dirt_plot = self._sv.contents[x][y]
            if dirt_plot and dirt_plot.is_fertilized then
               num_fertilized = num_fertilized + 1
            end
         end
      end

      self._sv.num_fertilized = num_fertilized
      self.__saved_variables:mark_changed()
   end

   if not self._sv.num_flooded then
      local num_flooded = 0
      for x=1, self._sv.size.x do
         for y=1, self._sv.size.y do
            local dirt_plot = self._sv.contents[x][y]
            if dirt_plot and dirt_plot.contents then
               if dirt_plot.contents:add_component('stonehearth:growing'):is_flooded() then
                  num_flooded = num_flooded + 1
               end
            end
         end
      end

      self._sv.num_flooded = num_flooded
      self.__saved_variables:mark_changed()
   end
end

function AceFarmerFieldComponent:_ensure_fertilize_layer()
   if not self._sv._fertilizable_layer then
      self._sv._fertilizable_layer = self:_create_field_layer('stonehearth_ace:farmer:field_layer:fertilizable')
      if self._is_restore then
         self._sv._fertilizable_layer:get_component('destination')
                        :set_reserved(_radiant.sim.alloc_region3()) -- xxx: clear the existing one from cpp land!
                        :set_auto_update_adjacent(true)
      end
      table.insert(self._field_listeners, radiant.events.listen(self._sv._fertilizable_layer, 'radiant:entity:pre_destroy', self, self._on_field_layer_destroyed))
   end
end

function AceFarmerFieldComponent:_ensure_fertilizer_preference()
   if not self._sv.fertilizer_preference then
      self._sv.fertilizer_preference = {
         quality = self:_get_default_fertilizer_preference()
      }
      self.__saved_variables:mark_changed()
   end
end

function AceFarmerFieldComponent:_get_default_fertilizer_preference()
   local def_to_worst = stonehearth.client_state:get_client_gameplay_setting(self._entity:get_player_id(), 'stonehearth_ace', 'default_to_worst_fertilizer', false)
   return (def_to_worst and -1) or 1
end

AceFarmerFieldComponent._old_on_field_created = FarmerFieldComponent.on_field_created
function AceFarmerFieldComponent:on_field_created(town, size)
   self:_old_on_field_created(town, size)
   radiant.terrain.place_entity(self._sv._fertilizable_layer, self._location)

	self:_create_water_listener()
end

AceFarmerFieldComponent._old_notify_plant_location_finished = FarmerFieldComponent.notify_plant_location_finished
function AceFarmerFieldComponent:notify_plant_location_finished(location)
   self:_old_notify_plant_location_finished(location)

   local p = Point3(location.x - self._location.x, 0, location.z - self._location.z)
   local fertilizable_layer = self._sv._fertilizable_layer
   local fertilizable_layer_region = fertilizable_layer:get_component('destination'):get_region()

   fertilizable_layer_region:modify(function(cursor)
      cursor:add_point(p)
   end)
end

function AceFarmerFieldComponent:notify_crop_fertilized(location)
   local p = Point3(location.x - self._location.x, 0, location.z - self._location.z)
   local fertilizable_layer = self._sv._fertilizable_layer
   local fertilizable_layer_region = fertilizable_layer:get_component('destination'):get_region()
   fertilizable_layer_region:modify(function(cursor)
      cursor:subtract_point(p)
   end)

   self:_update_crop_fertilized(p.x + 1, p.z + 1, true)
end

function AceFarmerFieldComponent:notify_crop_harvested(location)
   self:_update_crop_fertilized(location.x - self._location.x + 1, location.z - self._location.z + 1, false)
end

AceFarmerFieldComponent._old_plant_crop_at = FarmerFieldComponent.plant_crop_at
function AceFarmerFieldComponent:plant_crop_at(x_offset, z_offset)
   local crop = self:_old_plant_crop_at(x_offset, z_offset)

   local growing_comp = crop and crop:add_component('stonehearth:growing')
	if growing_comp then
      growing_comp:set_water_level(self._sv.water_level or 0)
      self:_create_flood_listener(crop)
      if growing_comp:is_flooded() then
         self._sv.num_flooded = self._sv.num_flooded + 1
         self.__saved_variables:mark_changed()
      end
	end
end

AceFarmerFieldComponent._old_notify_crop_destroyed = FarmerFieldComponent.notify_crop_destroyed
function AceFarmerFieldComponent:notify_crop_destroyed(x, z)
   local dirt_plot = self._sv.contents and self._sv.contents[x][z]
   if dirt_plot and dirt_plot.contents then
      self:_destroy_flood_listener(dirt_plot.contents:get_id())
   end
   self:_old_notify_crop_destroyed(x, z)
end

function AceFarmerFieldComponent:_destroy_flood_listeners()
   if self._flood_listeners then
      for _, listener in pairs(self._flood_listeners) do
         listener:destroy()
      end
   end
   self._flood_listeners = {}
end

function AceFarmerFieldComponent:_destroy_flood_listener(id)
   if self._flood_listeners[id] then
      self._flood_listeners[id]:destroy()
      self._flood_listeners[id] = nil
   end
end

function AceFarmerFieldComponent:_create_flood_listeners()
   self:_destroy_flood_listeners()

   for x=1, self._sv.size.x do
		for y=1, self._sv.size.y do
			local dirt_plot = self._sv.contents[x][y]
			if dirt_plot and dirt_plot.contents then
				self:_create_flood_listener(dirt_plot.contents)
			end
		end
	end
end

function AceFarmerFieldComponent:_create_flood_listener(crop)
   local listener = self._flood_listeners[crop:get_id()]
   if not listener then
      self._flood_listeners[crop:get_id()] = radiant.events.listen(crop, 'stonehearth_ace:growing:flooded_changed', function(is_flooded)
         if is_flooded then
            self._sv.num_flooded = self._sv.num_flooded + 1
         else
            self._sv.num_flooded = self._sv.num_flooded - 1
         end
         self.__saved_variables:mark_changed()
      end)
   end
end

AceFarmerFieldComponent._old_set_crop = FarmerFieldComponent.set_crop
function AceFarmerFieldComponent:set_crop(session, response, new_crop_id)
   local result = self:_old_set_crop(session, response, new_crop_id)

   self:_cache_best_water_level()
   self:_update_effective_water_level()

   return result
end

-- fertilizer preference is either a number (-1, 0, or 1) or a string (uri)
-- so we store it in a table similar to crafting ingredients material/uri
function AceFarmerFieldComponent:get_fertilizer_preference()
   return self._sv.fertilizer_preference
end

function AceFarmerFieldComponent:set_fertilizer_preference(preference)
   if preference.uri ~= self._sv.fertilizer_preference.uri or preference.quality ~= self._sv.fertilizer_preference.quality then
      -- uri outranks quality
      local uri = preference.uri
      local quality = (not preference.uri and (preference.quality or self:_get_default_fertilizer_preference())) or nil

      if uri ~= self._sv.fertilizer_preference.uri or quality ~= self._sv.fertilizer_preference.quality then
         self._sv.fertilizer_preference = {
            uri = uri,
            quality = quality
         }

         self.__saved_variables:mark_changed()
         radiant.events.trigger(self, 'stonehearth_ace:farmer_field:fertilizer_preference_changed')
         if self._sv._fertilizable_layer then
            stonehearth.ai:reconsider_entity(self._sv._fertilizable_layer, 'fertilizer preference changed')
         end
      end
   end
end

function AceFarmerFieldComponent:_update_crop_fertilized(x, z, fertilized)
   fertilized = fertilized or nil
   local dirt_plot = self._sv.contents[x][z]
   if dirt_plot then
      if fertilized and not dirt_plot.is_fertilized then
         self._sv.num_fertilized = self._sv.num_fertilized + 1
      elseif not fertilized and dirt_plot.is_fertilized then
         self._sv.num_fertilized = self._sv.num_fertilized - 1
      end
      dirt_plot.is_fertilized = fertilized
      self.__saved_variables:mark_changed()
   end
end

function AceFarmerFieldComponent:_create_water_listener()
	if self._water_listener then
		self:_destroy_water_listener()
	end

	local region = self._entity:get_component('region_collision_shape'):get_region():get()
						:extruded('x', 1, 1)
                  :extruded('z', 1, 1)
                  :extruded('y', 2, 0)
   local water_component = self._entity:add_component('stonehearth_ace:water_signal')
   self._water_signal = water_component:set_signal('farmer_field', region, {'water_volume'}, function(changes) self:_on_water_signal_changed(changes) end)
   self._sv.water_signal_region = region:duplicate()
   self:_set_water_volume(self._water_signal:get_water_volume())
end

function AceFarmerFieldComponent:_destroy_water_listener()
	if self._water_listener then
		self._water_listener:destroy()
		self._water_listener = nil
	end
end

function AceFarmerFieldComponent:_set_water_volume(volume)
   if volume then
      -- we consider the normal ideal water volume to crop ratio to be a filled half perimeter around an 11x11 farm of 66 crops
      -- i.e., 24 water / 66 crops = 4/11
      -- we compare that to our current volume to crop ratio
      local ideal_ratio = 4/11
      local this_ratio = volume / (math.ceil(self._sv.size.x/2) * self._sv.size.y)
      self._sv.water_level = this_ratio / ideal_ratio
   else
      self._sv.water_level = 0
   end
   self:_update_effective_water_level()
	self.__saved_variables:mark_changed()
end

function AceFarmerFieldComponent:_on_water_signal_changed(changes)
   local volume = changes.water_volume.value
   if not volume then
      return
   end
   
   self:_set_water_volume(volume)

	if self:_is_fallow() then
		return
	end

   -- if the water level only changed by a tiny bit, we don't want to recalculate water levels for everything
   -- once the change meets a particular threshold, go ahead and propogate
   local last_calculated = self._sv.last_calculated_water_volume
   if last_calculated and math.abs(last_calculated - volume) < RECALCULATE_THRESHOLD then
      return
   end

   self._sv.last_calculated_water_volume = volume
   self.__saved_variables:mark_changed()

	for x=1, self._sv.size.x do
		for y=1, self._sv.size.y do
			local dirt_plot = self._sv.contents[x][y]
			if dirt_plot and dirt_plot.contents then
				dirt_plot.contents:add_component('stonehearth:growing'):set_water_level(self._sv.water_level)
			end
		end
	end
end

-- returns the best affinity and then the next one so you can see the range until it would apply (and its effect)
function AceFarmerFieldComponent:get_best_water_level()
	if self:_is_fallow() then
		return nil
	end
	
	return stonehearth.town:get_best_water_level_from_climate(self._sv.current_crop_details.preferred_climate)
end

function AceFarmerFieldComponent:_cache_best_water_level()
   self._best_water_level, self._next_water_level = self:get_best_water_level()
end

function AceFarmerFieldComponent:_update_effective_water_level()
   local levels = stonehearth.constants.farming.water_levels
   local relative_level = levels.NONE

   if self._best_water_level and self._sv.water_level >= self._best_water_level.min_water then
      if not self._next_water_level or self._sv.water_level < self._next_water_level.min_water then
         relative_level = levels.PLENTY
      else
         relative_level = levels.EXTRA
      end
   elseif self._sv.water_level > 0 then
      relative_level = levels.SOME
   end

   self._sv.effective_water_level = relative_level
   self.__saved_variables:mark_changed()
end

AceFarmerFieldComponent._old__on_destroy = FarmerFieldComponent._on_destroy
function AceFarmerFieldComponent:_on_destroy()
   self:_old__on_destroy()
   
   radiant.entities.destroy_entity(self._sv._fertilizable_layer)
   self._sv._fertilizable_layer = nil

   self:_destroy_water_listener()
   self:_destroy_flood_listeners()
end

AceFarmerFieldComponent._old__reconsider_fields = FarmerFieldComponent._reconsider_fields
function AceFarmerFieldComponent:_reconsider_fields()
   for _, layer in ipairs({self._sv._soil_layer, self._sv._plantable_layer, self._sv._harvestable_layer, self._sv._fertilizable_layer}) do
      stonehearth.ai:reconsider_entity(layer, 'worker count changed')
   end
end

return AceFarmerFieldComponent
