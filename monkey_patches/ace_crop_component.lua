--[[
   Every time the crop grows, update its resource node resource. More mature crops
   yield better resources.
]]
local rng = _radiant.math.get_default_rng()
local item_quality_lib = require 'stonehearth_ace.lib.item_quality.item_quality_lib'
local CropComponent = require 'stonehearth.components.crop.crop_component'
local AceCropComponent = class()

function AceCropComponent:initialize()
   -- Initializing save variables
   self._sv.harvestable = false
   self._sv.stage = nil
   self._sv.product = nil
   self._sv._field = nil
   self._sv._field_offset_x = 0
   self._sv._field_offset_y = 0

   self:_load_json()
end

function AceCropComponent:_load_json()
   self._json = radiant.entities.get_json(self) or {}
   self._resource_pairings = self._json.resource_pairings
   self._harvest_threshhold = self._json.harvest_threshhold
end

AceCropComponent._ace_old_restore = CropComponent.restore
function AceCropComponent:restore()
   self:_ace_old_restore()

   if self._sv.megacrop_chance then
      self._sv._megacrop_chance = self._sv.megacrop_chance
      self._sv.megacrop_chance = nil
   end
   if self._sv.consider_megacrop then
      self._sv._consider_megacrop = self._sv.consider_megacrop
      self._sv.consider_megacrop = nil
   end
   if self._sv.is_megacrop then
      self._sv._is_megacrop = self._sv.is_megacrop
      self._sv.is_megacrop = nil
   end
end

AceCropComponent._ace_old_activate = CropComponent.activate
function AceCropComponent:activate()
   self:_ace_old_activate()

   self._megacrop_description = self._json.megacrop_description or stonehearth.constants.farming.DEFAULT_MEGACROP_DESCRIPTION
   self._megacrop_model_variant = self._json.megacrop_model_variant
   self._megacrop_change_scale = self._json.megacrop_change_scale
   if self._megacrop_change_scale == nil then
      self._megacrop_change_scale = stonehearth.constants.farming.DEFAULT_MEGACROP_SCALE
   end
   self._auto_harvest = self._json.auto_harvest
   self._post_harvest_stage = self._json.post_harvest_stage

   if not self._sv._megacrop_chance then
      self._sv._megacrop_chance = self._json.megacrop_chance or stonehearth.constants.farming.BASE_MEGACROP_CHANCE
   end
end

function AceCropComponent:get_post_harvest_stage()
   return self._post_harvest_stage
end

--- As we grow, change the resources we yield and, if appropriate, command harvest
function AceCropComponent:_on_grow_period(e)
   self._sv.stage = e.stage
   if e.stage then
      local resource_pairing_uri = self._resource_pairings[self._sv.stage]
      if resource_pairing_uri then
         if resource_pairing_uri == "" then
            resource_pairing_uri = nil
         end
         self._sv.product = resource_pairing_uri
      end
      if self._sv.stage == self._harvest_threshhold and self._sv._field then
         self._sv.harvestable = true
         self:_became_harvestable()
      else
         -- when resetting to an earlier stage, make it no longer harvestable
         if self._sv.harvestable then
            self._sv.harvestable = false
            self:_notify_unharvestable()
         end
      end
   end
   if e.finished and not self._post_harvest_stage then
      --TODO: is growth ever really complete? Design the difference between "can't continue" and "growth complete"
      if self._growing_listener then
         self._growing_listener:destroy()
         self._growing_listener = nil
      end
   end
   self.__saved_variables:mark_changed()
end

AceCropComponent._ace_old__notify_harvestable = CropComponent._notify_harvestable
function AceCropComponent:_notify_harvestable()
   self:_ace_old__notify_harvestable()
   -- try to auto-harvest the crop
   self._sv._field:try_harvest_crop(nil, self._sv._field_offset_x, self._sv._field_offset_y, nil, self._auto_harvest)
end

function AceCropComponent:_notify_unharvestable()
   radiant.assert(self._sv._field, 'crop %s has no field!', self._entity)
   self._sv._field:notify_crop_unharvestable(self._sv._field_offset_x, self._sv._field_offset_y)
end

-- separate this out into its own function so it's easier to modify
function AceCropComponent:_became_harvestable()
   if self._sv._consider_megacrop and self._sv._is_megacrop == nil then
      if rng:get_real(0, 1) < self._sv._megacrop_chance then
         self:_set_megacrop()
      end
   end

   self:_notify_harvestable()
end

function AceCropComponent:set_fertilized()
   -- not really used at the moment, maybe refactor the fertilize ai to do more of it in here
end

function AceCropComponent:set_consider_megacrop()
   if not self._sv._consider_megacrop then
      self._sv._consider_megacrop = true
      --self.__saved_variables:mark_changed()
   end
end

function AceCropComponent:apply_megacrop_chance_multiplier(multiplier)
   if multiplier ~= 1 and self._sv._megacrop_chance ~= 0 then
      self._sv._megacrop_chance = self._sv._megacrop_chance * multiplier
      --self.__saved_variables:mark_changed()
   end
end

function AceCropComponent:is_megacrop()
   return self._sv._is_megacrop
end

function AceCropComponent:_set_megacrop()
   self._sv._is_megacrop = true
   
   if self._megacrop_description then
      radiant.entities.set_description(self._entity, self._megacrop_description)
   end

   local render_info = self._entity:get_component('render_info')
   if self._megacrop_model_variant then
      render_info:set_model_variant(self._megacrop_model_variant)
   end
   if self._megacrop_change_scale then
      render_info:set_scale(render_info:get_scale() * (self._megacrop_change_scale + rng:get_real(-0.05, 0.05)))
   end

   --self.__saved_variables:mark_changed()
end

function AceCropComponent:get_harvest_items(owner, num_stacks)
   local primary_item
   local items = {}

   owner = owner or self._entity
   local product_uri = self:get_product()
   local quality = radiant.entities.get_item_quality(self._entity)
   local megacrop_data = radiant.entities.get_entity_data(self._entity, 'stonehearth_ace:megacrop') or {}
   
   if self:is_megacrop() then
      local num_to_spawn = megacrop_data.num_to_spawn or 3
      local other_items = megacrop_data.other_items
      local pickup_new = other_items and megacrop_data.pickup_new ~= nil and megacrop_data.pickup_new
      
      -- spawn "other" items first, so we can easily separate the first one
      if other_items then
         for uri, count in pairs(other_items) do
            for i = 1, count do
               local item = self:_create_item(player_id, uri, quality)
               if item then
                  if not primary_item then
                     primary_item = item
                  else
                     items[item:get_id()] = item
                  end
               end
            end
         end
      end

      -- spawn more of the product
      for i = 1, num_to_spawn do
         local item = self:_create_item(owner, product_uri, quality, 1, true)
         if item then
            items[item:get_id()] = item
         end
      end
   end

   if not primary_item and (not self:is_megacrop() or not megacrop_data.return_immediately) then
      primary_item = self:_create_item(owner, product_uri, quality, num_stacks)
   end

   return primary_item, items
end

function AceCropComponent:_create_item(player_id, uri, crop_quality, num_stacks, max_stacks)
   if not uri then
      return
   end

   local product = radiant.entities.create_entity(uri, { owner = player_id })
   local entity_forms = product:get_component('stonehearth:entity_forms')

   --If there is an entity_forms component, then you want to put the iconic version
   --in the farmer's arms, not the actual entity (ie, if we had a chair crop)
   --This also prevents the item component from being added to the full sized versions of things.
   if entity_forms then
      local iconic = entity_forms:get_iconic_entity()
      if iconic then
         product = iconic
      end
   end

   local stacks_component = product:get_component('stonehearth:stacks')
   if stacks_component then
      stacks_component:set_stacks((max_stacks and stacks_component:get_max_stacks()) or num_stacks or 1)
   end

   if crop_quality > 1 then
      item_quality_lib.copy_quality(self._entity, product)
   end

   return product
end

return AceCropComponent