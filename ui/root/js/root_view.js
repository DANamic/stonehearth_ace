App.RootController.reopen({
   _minAutoSaveInterval: 5,   // minutes
   
   init: function() {
      var self = this;
      self._super();

      self._autoSaveInterval = self._minAutoSaveInterval * 60 * 1000

      radiant.call('radiant:get_config', 'mods.stonehearth_ace.auto_save_interval')
         .done(function(response) {
            self._setAutoSaveInterval(response['mods.stonehearth_ace.auto_save_interval']);
         });
      $(top).on("auto_save_interval_changed", function (_, e) {
         self._setAutoSaveInterval(e.value);
      });
   },

   _setAutoSaveInterval: function(interval) {
      self._autoSaveInterval = Math.max(self._minAutoSaveInterval, parseInt(interval)) * 60 * 1000;
   },

   // have to override this to defer resume
   _autoSave: function() {
      var self = this;
      var saveView = App.stonehearthClient.getSaveView();
      var enabled = saveView.get('auto_save');
      var escMenuView = App.gameView ? App.gameView.getView(App.StonehearthEscMenuView) : null;
      var escMenuVisible = escMenuView ? (!escMenuView.isDestroyed && !escMenuView.isDestroying) : false;

      if (enabled && !escMenuVisible) {
         radiant.call('stonehearth:dm_pause_game')
            .done(function(response) {
               saveView.send('saveGame', 'auto_save', function() {
                  radiant.call('stonehearth:dm_resume_game');
               });
            });
      }
   },

   actions: {
      // every X minutes, check if autosave is enabled, and if it is, save.
      // override this function completely to use timeouts instead of intervals to easily transition auto save intervals
      tryAutoSave: function(start) {
         var self = this;
          // Get the controller once to initialize it (Sigh)
          // Otherwise we don't get the controller when we first try to save -yshan
         var saveView = App.stonehearthClient.getSaveView();
         if (start) {
            this._timeoutTicket = setTimeout(function autoSaveTimeout() {
                  //only autosave if we're the host
                  if (App.stonehearthClient.isHostPlayer()) {
                     self._autoSave();
                  }
                  self._timeoutTicket = setTimeout(autoSaveTimeout, self._autoSaveInterval);
               }, self._autoSaveInterval);
         } else {
            clearTimeout(this._timeoutTicket);
         }
      },
   },
}),

// other modders can also reopen this, override init, and add their own custom modes and entity mode checks
App.RootView.reopen({
   init: function() {
      this._super();
      var self = this;

      // also apply any stonehearthClient changes we want to make here
      self._applyStonehearthClientChanges();

      self._game_mode_manager.addCustomMode("military", "military"); //, null, "AceMilitaryModeView", true);
      self._game_mode_manager.addCustomMode("connection", "hud");
      self._game_mode_manager.addCustomEntityModeCheck(self._ACE_getCustomModeForEntity);
   },

   _ACE_getCustomModeForEntity: function(modes, entity) {
      if (entity['stonehearth_ace:patrol_banner'] ||            entity['stonehearth:party']) {
         return modes.MILITARY;
      }

      if (entity['stonehearth_ace:connection']) {
         return modes.CONNECTION;
      }

      return null;
   },

   _applyStonehearthClientChanges: function() {
      App.stonehearthClient._placeItemOrItemType = function (placementType, toolName, item, quality) {
         var self = this;
         var placementCall = placementType == 'item' ? 'stonehearth:choose_place_item_location' : 'stonehearth:choose_place_item_type_location';

         radiant.call('stonehearth:check_can_place_item', item, quality)
            .done(function (response) {
               radiant.call('stonehearth_ace:get_custom_tooltip_command', item, 'stonehearth:ui.game.menu.build_menu.items.place_item')
               .done(function (r) {
                  var custom_tooltips = r.custom_tooltips;
                  var tip_title = custom_tooltips.tip_title || 'stonehearth:ui.game.menu.build_menu.items.place_item.tip_title';
                  var tip_description = custom_tooltips.tip_description || 'stonehearth:ui.game.menu.build_menu.items.place_item.tip_description';
                  var tip_bindings = custom_tooltips.tip_bindings || {left_binding: 'build:rotate:left', right_binding: 'build:rotate:right'};
                  self.showTipWithKeyBindings(tip_title, tip_description, tip_bindings);

                  App.setGameMode('place');
                  return self._callTool(toolName, function() {
                     return radiant.call(placementCall, item, quality)
                        .done(function(response) {
                           radiant.call('radiant:play_sound', {'track' : 'stonehearth:sounds:place_structure'} )
                           if ((placementType == 'itemType') && response.more_items) {
                              self.placeItemType(item, quality);
                           } else {
                              self.hideTip();
                           }
                        })
                        .fail(function(response) {
                           //App.setGameMode('normal');
                           self.hideTip();
                        })
                        .always(function(response) {
                           if (placementType == 'item') {
                              App.setGameMode('normal');
                              self.hideTip();
                           }
                        });
                  });
               });
            })
            .fail(function(response) {
               self.showTip(i18n.t('stonehearth:ui.game.menu.build_menu.items.cannot_place_item.tip_title'),
                            i18n.t('stonehearth:ui.game.menu.build_menu.items.cannot_place_item.tip_description', {
                               tag: i18n.t("i18n(stonehearth:ui.game.unit_frame.placement_tags." + response.placement_tag + ")"),
                               num: response.num_placed || 0,
                               max: response.max_placeable || 0
                            }),
                            {warning: 'warning'});
            });
      };
   }
});