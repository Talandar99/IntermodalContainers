local weight = require("weight")

weight.calc()

log(serpent.block(weight.lookup))

--local weight = require("weight")

for _, recipe in pairs(data.raw.recipe) do
	local ingredients = recipe.ingredients or (recipe.normal and recipe.normal.ingredients)
	if ingredients then
		local container_item, packed_item_name = false, nil

		for _, ing in pairs(ingredients) do
			local name = ing.name or ing[1]
			if name == "ic-container" then
				container_item = true
			else
				packed_item_name = name
			end
		end

		if container_item and packed_item_name then
			local result = recipe.result or (recipe.results and recipe.results[1] and recipe.results[1].name)
			if result and weight.lookup[packed_item_name] then
				local item_proto = data.raw.item[result]
				local packed_proto = data.raw.item[packed_item_name]
				if item_proto and packed_proto then
					item_proto.weight = weight.lookup[packed_item_name]
						* packed_proto.stack_size
						* settings.startup["ic-stacks-per-container"].value
				end
			end
		end
	end
end
