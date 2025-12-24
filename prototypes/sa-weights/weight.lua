local maps = require("prototypes.sa-weights.maps")

local weight = {}

weight.lookup = {}

-- Calculate the weights all at once for efficiency
-- I should probably store this somewhere since I'm not sure if weight.lookup is lost between loading stages, but someone else can figure that out (you probably want to reocmpute it to be sure anyways)
-- If recompute is passed in and true, weight.lookup will be recalculated even if it was already found
weight.calc = function(recompute)
	if not recompute and next(weight.lookup) ~= nil then
		return
	end

	maps.call_loaders()

	local lookup = {}

	-- Details for weight calculation found from URL below (version 2.0.72); quotes from page included for clarity
	-- https://lua-api.factorio.com/2.0.72/auxiliary/item-weight.html

	local default_weight = data.raw["utility-constants"].default.default_item_weight
	local rocket_lift_weight = data.raw["utility-constants"].default.rocket_lift_weight

	local item_to_first_recipe = {}
	for _, item in pairs(maps.items) do
		-- Check for manually set weight; if it doesn't
		if item.weight ~= nil then
			lookup[item.name] = item.weight
		else
			-- Quote: If an item has the "only-in-cursor" and "spawnable" flags, its weight will be 0.
			if item.flags ~= nil then
				local give_zero_weight = false
				for _, flag in pairs(item.flags) do
					if flag == "only-in-cursor" or flag == "spawnable" then
						give_zero_weight = true
						break
					end
				end
				if give_zero_weight then
					lookup[item.name] = 0
				end
			end

			-- Only continue if we didn't set weight to zero just now
			if lookup[item.name] == nil then
				local related_recipes = maps.item_to_recipe[item.name]
				local valid_recipes = {}
				for recipe_name, _ in pairs(related_recipes) do
					local recipe = data.raw.recipe[recipe_name]
					-- Quote: Recipes that don't allow decomposition are not considered
					if recipe.allow_decomposition or recipe.allow_decomposition == nil then
						table.insert(valid_recipes, recipe)
					end
				end
				-- Quote: If an item has no recipe to produce it, it'll fall back to the default item weight.
				if next(valid_recipes) == nil then
					lookup[item.name] = default_weight
				else
					-- Quote: If an item has multiple recipes, it picks the first recipe, according to the sorting described at the bottom of this page.
					-- (Note that this sorting process applies for one recipe as well, since any ordering will put it first trivially)
					-- Quote: The sorting works by considering the following attributes in order, preferring recipes that fulfill them:
					table.sort(valid_recipes, function(r1, r2)
						-- Quote: The name of the recipe is identical to the item name.
						local function check_name(recipe)
							if recipe.name == item.name then
								return 0
							else
								return 1
							end
						end
						-- Quote: The recipe is not using the item as a catalyst.
						local function using_as_catalyst(recipe)
							if
								(recipe.ignored_by_productivity ~= nil and recipe.ignored_by_productivity > 0)
								or (
									recipe.ignored_by_productivity == nil
									and recipe.ignored_by_stats ~= nil
									and recipe.ignored_by_stats > 0
								)
							then
								-- Being a catalyst puts it later
								return 1
							else
								return 0
							end
						end
						-- Quote: The recipe can be used as an intermediate while hand-crafting.
						local function usable_in_handcrafting(recipe)
							if recipe.allow_as_intermediate or recipe.allow_as_intermediate == nil then
								return 0
							else
								return 1
							end
						end
						-- The recipe's category, subgroup, then order.
						local function category_order(recipe)
							local category = data.raw["recipe-category"][recipe.category or "crafting"]
							return category.order or category.name
						end
						local function subgroup_order(recipe)
							local subgroup = data.raw["item-subgroup"][maps.recipe_subgroup[recipe.name]]
							return subgroup.order or subgroup.name
						end
						local function recipe_order(recipe)
							return recipe.order or recipe.name
						end

						for _, checker in pairs({
							check_name,
							using_as_catalyst,
							usable_in_handcrafting,
							category_order,
							subgroup_order,
							recipe_order,
						}) do
							local order1 = checker(r1)
							local order2 = checker(r2)
							if order1 < order2 then
								return true
							elseif order2 < order1 then
								return false
							end
						end

						-- Note: Technically, everything including recipe orders can be the same, but behavior then is undefined; let's just return false
						return false
					end)

					item_to_first_recipe[item.name] = valid_recipes[1]
				end
			end
		end
	end

	-- Now, let's do a mini topological sort on the item --> item graph using Kahn's algorithm

	-- First, construct the graph
	local item_graph = {}
	local open = {}
	local in_open = {}
	local reqs_total = {}
	local reqs_satisfied = {}
	-- We need to add all nodes separately since not every item was added to item_to_first_recipe
	for item_name, _ in pairs(maps.items) do
		item_graph[item_name] = {
			pre = {},
			dep = {},
		}
		reqs_total[item_name] = 0
		reqs_satisfied[item_name] = 0
	end
	for item_name, recipe in pairs(item_to_first_recipe) do
		-- Don't add prereqs if the item already has a weight, since then it might get added to open twice
		if lookup[item_name] == nil then
			if recipe.ingredients ~= nil then
				for _, ing in pairs(recipe.ingredients) do
					if ing.type == "item" then
						item_graph[item_name].pre[ing.name] = true
						reqs_total[item_name] = reqs_total[item_name] + 1
					end
				end
			end
		end
		-- Add sources (items with no prereqs)
		if reqs_total[item_name] == 0 then
			table.insert(open, item_name)
			in_open[item_name] = true
		end
	end
	-- Also add items that already have weights, but weren't in item_to_first_recipe as sources
	for item_name, _ in pairs(maps.items) do
		if lookup[item_name] ~= nil and item_to_first_recipe[item_name] == nil then
			table.insert(open, item_name)
			in_open[item_name] = true
		end
	end
	-- Add dependents
	for item_name, node in pairs(item_graph) do
		for pre, _ in pairs(node.pre) do
			item_graph[pre].dep[item_name] = true
		end
	end

	local ind = 1
	while true do
		if ind > #open then
			break
		end

		local curr_item = open[ind]
		local curr_item_prot = maps.items[curr_item]

		local curr_weight = lookup[curr_item]

		-- Calculate weight if we haven't done so yet
		if curr_weight == nil then
			local curr_recipe = item_to_first_recipe[curr_item]
			-- We might end up recalculating the recipe cost for a recipe that somehow is canonical for more than one item, but that should be rare and not worth the effort to optimize for

			-- Quote: The recipe weight is then calculated by iterating over all ingredients:
			local recipe_weight = 0
			if curr_recipe.ingredients ~= nil then
				for _, ing in pairs(curr_recipe.ingredients) do
					if ing.type == "item" then
						-- Quote: For each item ingredient, the weight is increased by item_weight * item_ingredient_count.
						recipe_weight = recipe_weight + lookup[ing.name] * ing.amount
					else
						-- Quote: For each fluid ingredient, the weight is increased by fluid_ingredient_amount * 100.
						recipe_weight = recipe_weight + ing.amount * 100
					end
				end
			end
			-- Quote: If the resulting recipe weight is 0, the item's weight will fall back to the default item weight.
			if recipe_weight == 0 then
				lookup[curr_item] = default_weight
			else
				-- Quote: The game then determines the product count of the recipe by iterating all products and adding up the expected (ie. after probabilities) count for all item products. Fluid products are skipped.
				local product_count = 0
				if curr_recipe.results ~= nil then
					for _, result in pairs(curr_recipe.results) do
						if result.type == "item" then
							local amount = result.amount or ((result.amount_min + result.amount_max) / 2)
							local probability = result.probability or 1
							product_count = product_count + amount * probability
						end
					end
				end
				-- Quote: If the recipe's product count is 0, the item's weight will fall back to the default item weight.
				if product_count == 0 then
					lookup[curr_item] = default_weight
				else
					-- Quote: Next, an intermediate result will be determined as (recipe_weight / product_count) * ingredient_to_weight_coefficient (see ingredient_to_weight_coefficient, which defaults to 0.5).
					local intermediate_result = (recipe_weight / product_count)
						* (curr_item_prot.ingredient_to_weight_coefficient or 0.5)

					if not curr_recipe.allow_productivity then
						-- Quote: Following this, if a recipe doesn't support productivity, its simple result is determined as rocket_lift_weight / stack_size (see rocket_lift_weight and stack_size).
						local simple_result = rocket_lift_weight / curr_item_prot.stack_size
						-- Quote: If this simple result is larger than or equal to the intermediate result, it becomes the item's weight.
						if simple_result >= intermediate_result then
							lookup[curr_item] = simple_result
						end
					end

					-- Quote: Check if we still haven't assigned weight (either the recipe supports productivity or didn't satisfy simple_result constraints)
					if lookup[curr_item] == nil then
						-- Quote: Otherwise, the game determines the amount of stacks that would result from the intermediate result as rocket_lift_weight / intermediate_result / stack_size.
						local stack_amount = rocket_lift_weight / intermediate_result / curr_item_prot.stack_size
						-- Quote: If this amount is less than or equal to 1, the intermediate result becomes the item's weight.
						if stack_amount <= 1 then
							lookup[curr_item] = intermediate_result
						-- Quote: Else, the item's weight is set to rocket_lift_weight / floor(stack_amount) / stack_size.
						else
							lookup[curr_item] = rocket_lift_weight
								/ math.floor(stack_amount)
								/ curr_item_prot.stack_size
						end
					end
				end
			end
		end

		-- Add dependents to open
		for dep, _ in pairs(item_graph[curr_item].dep) do
			reqs_satisfied[dep] = reqs_satisfied[dep] + 1
			if reqs_satisfied[dep] == reqs_total[dep] then
				if not in_open[dep] then
					table.insert(open, dep)
					in_open[dep] = true
				end
			end
		end

		ind = ind + 1
	end

	-- Put default item weights on the rest (which must have been in a loop)
	for item_name, _ in pairs(maps.items) do
		if lookup[item_name] == nil then
			-- Take floor so that weights are always integers
			lookup[item_name] = math.floor(default_weight)
		end
	end

	-- Update table values for anything that holds a copy of lookup
	local keys_to_remove = {}
	for k, _ in pairs(weight.lookup) do
		keys_to_remove[k] = true
	end
	for k, _ in pairs(keys_to_remove) do
		weight.lookup[k] = nil
	end
	for k, v in pairs(lookup) do
		weight.lookup[k] = v
	end
end

return weight
