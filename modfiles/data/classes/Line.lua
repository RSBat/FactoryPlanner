-- 'Class' representing an assembly line producing a recipe or representing a subfloor
Line = {}

function Line.init(recipe)
    local is_standalone_line = (recipe ~= nil)

    return {
        recipe = recipe,  -- can be nil
        percentage = (is_standalone_line) and 100 or nil,
        machine = nil,
        beacon = nil,
        total_effects = nil,  -- initialized after a machine is set
        energy_consumption = 0,
        pollution = 0,
        Product = Collection.init("Item"),
        Byproduct = Collection.init("Item"),
        Ingredient = Collection.init("Item"),
        priority_product_proto = nil,  -- set by the user
        comment = nil,
        production_ratio = (is_standalone_line) and 0 or nil,
        uncapped_production_ratio = (is_standalone_line) and 0 or nil,
        subfloor = nil,
        valid = true,
        class = "Line"
    }
end


function Line.add(self, object)
    object.parent = self
    return Collection.add(self[object.class], object)
end

function Line.remove(self, dataset)
    return Collection.remove(self[dataset.class], dataset)
end

function Line.replace(self, dataset, object)
    return Collection.replace(self[dataset.class], dataset, object)
end

function Line.clear(self, class)
    self[class] = Collection.clear(self[class])
end


function Line.get(self, class, dataset_id)
    return Collection.get(self[class], dataset_id)
end

function Line.get_in_order(self, class, reverse)
    return Collection.get_in_order(self[class], reverse)
end

function Line.get_by_gui_position(self, class, gui_position)
    return Collection.get_by_gui_position(self[class], gui_position)
end

function Line.get_by_name(self, class, name)
    return Collection.get_by_name(self[class], name)
end

function Line.get_by_type_and_name(self, class, type, name)
    return Collection.get_by_type_and_name(self[class], type, name)
end


-- Returns whether the given machine can be used for this line/recipe
function Line.is_machine_applicable(self, machine_proto)
    local recipe_proto = self.recipe.proto
    local valid_ingredient_count = (machine_proto.ingredient_limit >= recipe_proto.type_counts.ingredients.items)
    local valid_input_channels = (machine_proto.fluid_channels.input >= recipe_proto.type_counts.ingredients.fluids)
    local valid_output_channels = (machine_proto.fluid_channels.output >= recipe_proto.type_counts.products.fluids)

    return (valid_ingredient_count and valid_input_channels and valid_output_channels)
end

-- Changes the machine either to the given machine or moves it in the given direction
-- Returns false if no machine is applied because none can be found, true otherwise
function Line.change_machine(self, player, machine_proto, direction)
    -- Set the machine to the default one
    if machine_proto == nil and direction == nil then
        local machine_category_id = global.all_machines.map[self.recipe.proto.category]
        local default_machine_proto = prototyper.defaults.get(player, "machines", machine_category_id)

        -- If no default machine is found, this category has no machines
        if default_machine_proto == nil then return false end
        return Line.change_machine(self, player, default_machine_proto, nil)

    -- Set machine directly
    elseif machine_proto ~= nil and direction == nil then
        -- Try setting a higher tier machine until it sticks or nothing happens
        -- Returns false if no machine fits at all, so an appropriate error can be displayed
        if not Line.is_machine_applicable(self, machine_proto) then
            return Line.change_machine(self, player, machine_proto, "positive")

        else
            if not self.machine then
                self.machine = Machine.init_by_proto(machine_proto)
                self.machine.parent = self

                -- Initialize total_effects, now that the line has a machine
                Line.summarize_effects(self, false, false)

            else
                self.machine.proto = machine_proto

                -- Check if the fuel is still compatible, remove it otherwise
                local fuel = self.machine.fuel
                if fuel ~= nil and (not fuel.valid or not (machine_proto.energy_type == "burner"
                  and machine_proto.burner.categories[fuel.proto.category])) then
                    self.machine.fuel = nil
                end

                -- Adjust modules (ie. trim them if needed)
                Machine.normalize_modules(self.machine, false, true)

                -- Adjust beacon (ie. remove if machine does not allow beacons)
                if self.machine.proto.allowed_effects == nil then Line.set_beacon(self, nil) end
            end

            -- Set the machine-fuel, if appropriate
            Machine.find_fuel(self.machine, player)

            return true
        end

    -- Bump machine in the given direction
    elseif direction ~= nil then
        -- Uses the given machine proto, if given, otherwise bumps the line's existing machine
        machine_proto = machine_proto or self.machine.proto

        local machine_category_id = global.all_machines.map[machine_proto.category]
        local category_machines = global.all_machines.categories[machine_category_id].machines

        if direction == "positive" then
            if machine_proto.id < #category_machines then
                local new_machine = category_machines[machine_proto.id + 1]
                return Line.change_machine(self, player, new_machine, nil)
            else
                local message = {"fp.error_object_cant_be_up_downgraded", {"fp.machine"}, {"fp.upgraded"}}
                titlebar.enqueue_message(player, message, "error", 1, false)
                return false
            end
        else  -- direction == "negative"
            if machine_proto.id > 1 then
                local new_machine = category_machines[machine_proto.id - 1]
                return Line.change_machine(self, player, new_machine, nil)
            else
                local message = {"fp.error_object_cant_be_up_downgraded", {"fp.machine"}, {"fp.downgraded"}}
                titlebar.enqueue_message(player, message, "error", 1, false)
                return false
            end
        end
    end
end


-- Sets the beacon appropriately, recalculating total_effects
function Line.set_beacon(self, beacon)
    self.beacon = beacon  -- can be nil

    if beacon then
        self.beacon.parent = self
        Beacon.trim_modules(self.beacon)
    end

    Line.summarize_effects(self, false, true)
end


-- Updates the line attribute containing the total module effects of this line (modules+beacons)
function Line.summarize_effects(self, summarize_machine, summarize_beacon)
    if self.subfloor ~= nil or self.machine == nil then return nil end

    if summarize_machine then Machine.summarize_effects(self.machine) end
    if summarize_beacon and self.beacon then Beacon.summarize_effects(self.beacon) end

    local module_effects = {consumption = 0, speed = 0, productivity = 0, pollution = 0}

    local effects_table = {self.machine.total_effects}
    if self.beacon then table.insert(effects_table, self.beacon.total_effects) end

    for _, effect_table in pairs(effects_table) do
        for name, effect in pairs(effect_table) do
            module_effects[name] = module_effects[name] + effect
        end
    end

    self.total_effects = module_effects
end

-- Returns the total effects influencing this line, including mining productivity
function Line.get_total_effects(self, player)
    local effects = cutil.shallowcopy(self.total_effects)

    -- Add mining productivity, if applicable
    local mining_productivity = 0
    if self.machine.proto.mining then
        local subfactory = self.parent.parent
        if subfactory.mining_productivity ~= nil then
            mining_productivity = (subfactory.mining_productivity / 100)
        else
            mining_productivity = player.force.mining_drill_productivity_bonus
        end
    end
    effects.productivity = effects.productivity + mining_productivity

    return effects
end


-- Returns a table indicating the compatibility of the given module with this line and the given beacon
function Line.get_beacon_module_characteristics(self, beacon_proto, module_proto)
    local compatible = true
    local recipe, machine = self.recipe, self.machine

    if not self.valid or not recipe.valid or not machine.valid then compatible = false end

    if compatible then
        if table_size(module_proto.limitations) ~= 0 and recipe.proto.use_limitations
          and not module_proto.limitations[recipe.proto.name] then
            compatible = false
          end
    end

    if compatible then
        local machine_effects, beacon_effects = machine.proto.allowed_effects, beacon_proto.allowed_effects
        if machine_effects == nil or beacon_effects == nil then
            compatible = false
        else
            for effect_name, _ in pairs(module_proto.effects) do
                if machine_effects[effect_name] == false or beacon_effects[effect_name] == false then
                    compatible = false
                    break
                end
            end
        end
    end

    return { compatible = compatible }
end


function Line.pack(self)
    local packed_line = {
        comment = self.comment,
        class = self.class
    }

    if self.subfloor ~= nil then
        packed_line.subfloor = Floor.pack(self.subfloor)

    else
        packed_line.recipe = Recipe.pack(self.recipe)
        packed_line.percentage = self.percentage

        packed_line.machine = Machine.pack(self.machine)
        packed_line.beacon = (self.beacon) and Beacon.pack(self.beacon) or nil

        -- If this line has no priority_product, the function will return nil
        packed_line.priority_product_proto = prototyper.util.simplify_prototype(self.priority_product_proto)
    end

    return packed_line
end

function Line.unpack(packed_self)
    -- Only lines without subfloors are ever unpacked, so it can be treated as such
    local self = Line.init(packed_self.recipe)

    self.machine = Machine.unpack(packed_self.machine)
    self.machine.parent = self

    self.beacon = (packed_self.beacon) and Beacon.unpack(packed_self.beacon) or nil
    if self.beacon then self.beacon.parent = self end

    self.comment = packed_self.comment
    self.percentage = packed_self.percentage
    self.priority_product_proto = packed_self.priority_product_proto
    -- Effects are summarized by the ensuing validation

    return self
end


-- Needs validation: recipe, machine, beacon, priority_product_proto, subfloor
function Line.validate(self)
    self.valid = true

    if self.subfloor then  -- when this line has a subfloor, only the subfloor need to be checked
        self.valid = Floor.validate(self.subfloor) and self.valid

    else
        self.valid = Recipe.validate(self.recipe) and self.valid

        self.valid = Machine.validate(self.machine) and self.valid

        if self.beacon then self.valid = Beacon.validate(self.beacon) and self.valid end

        if self.priority_product_proto then
            self.valid = prototyper.util.validate_prototype_object(self, "priority_product_proto", "items", "type")
              and self.valid
        end

        if self.valid then Line.summarize_effects(self, false, false) end
    end

    return self.valid
end

-- Needs repair: recipe, machine, beacon, priority_product_proto, subfloor
function Line.repair(self, player)
    self.valid = true

    if self.subfloor then
        if not self.subfloor.valid then
            -- Repairing a floor always makes it valid, or removes it if left empty
            Floor.repair(self.subfloor, player)
        end

    else
        if not self.recipe.valid then
            self.valid = Recipe.repair(self.recipe, nil)
        end

        if self.valid and not self.machine.valid then
            self.valid = Machine.repair(self.machine, player)
        end

        if self.valid and self.beacon and not self.beacon.valid then
            -- Repairing an invalid beacon will remove it, leading to a valid line
            Beacon.repair(self.beacon, nil)
        end

        if self.valid and self.priority_product_proto and self.priority_product_proto.simplified then
            self.priority_product_proto = nil
        end

        if self.valid then Line.summarize_effects(self, false, false) end
    end

    return self.valid
end