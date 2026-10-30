# WorldFeatureCatalog.gd
class_name WorldFeatureCatalog
extends RefCounted

const LANDFORM_PROFILES = [
	{
		"id": "alpine_peaks",
		"name": "Alpine Peaks",
		"description": "Steep, dramatic ridges with high elevation and snow-capped zones.",
		"mountain_scale": 70.0,
		"continent_scale": 12.0
	},
	{
		"id": "rolling_highlands",
		"name": "Rolling Highlands",
		"description": "Gentle hills with wide fertile valleys and undulating terrain.",
		"mountain_scale": 35.0,
		"continent_scale": 8.0
	},
	{
		"id": "canyon_gorge",
		"name": "Canyon Gorge",
		"description": "Deep carved gorges with sheer rock walls and flat tablelands.",
		"mountain_scale": 50.0,
		"continent_scale": 20.0
	},
	{
		"id": "rift_valley",
		"name": "Rift Valley",
		"description": "Low sunken basin between flanking mountain escarpments.",
		"mountain_scale": 45.0,
		"continent_scale": 15.0
	},
	{
		"id": "alien_xenolith",
		"name": "Alien Xenolith",
		"description": "Irregular jagged terraces, spires, and surreal landforms.",
		"mountain_scale": 60.0,
		"continent_scale": 18.0
	}
]

const HYDROLOGY_PATTERNS = [
	{
		"id": "meandering_river",
		"name": "Meandering River",
		"description": "Sinusoidal river winding through valleys towards lower terrain."
	},
	{
		"id": "confluence_network",
		"name": "Confluence Network",
		"description": "Multiple alpine spring tributaries merging into a central trunk river."
	},
	{
		"id": "u_shaped_loop",
		"name": "U-Shaped Loop",
		"description": "River describing a broad curve around central highlands."
	},
	{
		"id": "wetland_lakes",
		"name": "Wetland Lakes",
		"description": "Chain of interconnected shallow lakes and water basins."
	}
]

const BIOME_ARCHETYPES = [
	{
		"id": "ancient_temperate_wilds",
		"name": "Ancient Temperate Wilds",
		"sky_color": "light blue",
		"horizon_color": "silver",
		"ground_tint": "forest green",
		"fog_color": "silver",
		"fog_density": 0.0015,
		"light_color": "pale gold",
		"light_energy": 1.0,
		"special_event": "none"
	},
	{
		"id": "prismatic_crystal_grove",
		"name": "Prismatic Crystal Grove",
		"sky_color": "violet",
		"horizon_color": "cyan",
		"ground_tint": "turquoise",
		"fog_color": "violet",
		"fog_density": 0.004,
		"light_color": "cyan",
		"light_energy": 0.85,
		"special_event": "crystal_rain"
	},
	{
		"id": "bioluminescent_fungal_marsh",
		"name": "Bioluminescent Fungal Marsh",
		"sky_color": "dark violet",
		"horizon_color": "magenta",
		"ground_tint": "teal",
		"fog_color": "magenta",
		"fog_density": 0.006,
		"light_color": "cyan",
		"light_energy": 0.65,
		"special_event": "floating_spores"
	},
	{
		"id": "alien_xenolith_basin",
		"name": "Alien Xenolith Basin",
		"sky_color": "deep blue",
		"horizon_color": "neon green",
		"ground_tint": "purple",
		"fog_color": "neon green",
		"fog_density": 0.005,
		"light_color": "purple",
		"light_energy": 0.75,
		"special_event": "fireflies"
	},
	{
		"id": "obsidian_volcanic_wastes",
		"name": "Obsidian Volcanic Wastes",
		"sky_color": "black",
		"horizon_color": "crimson",
		"ground_tint": "dark gray",
		"fog_color": "crimson",
		"fog_density": 0.008,
		"light_color": "orange",
		"light_energy": 0.9,
		"special_event": "embers"
	},
	{
		"id": "snowy_alpine_tundra",
		"name": "Snowy Alpine Tundra",
		"sky_color": "light blue",
		"horizon_color": "white",
		"ground_tint": "white",
		"fog_color": "white",
		"fog_density": 0.003,
		"light_color": "white",
		"light_energy": 1.1,
		"special_event": "crystal_rain"
	}
]

const FLORA_SPECIES = [
	{"archetype": "canopy_tree", "name": "Ancient Canopy Oak", "default_density": 0.007, "scale_min": 1.3, "scale_max": 2.4, "trunk_color": "dark brown", "foliage_color": "forest green", "emissive": false},
	{"archetype": "canopy_tree", "name": "Prismatic Canopy Spire", "default_density": 0.007, "scale_min": 1.3, "scale_max": 2.4, "trunk_color": "purple", "foliage_color": "cyan", "emissive": true},
	{"archetype": "canopy_tree", "name": "Giant Spore Cap", "default_density": 0.008, "scale_min": 1.4, "scale_max": 2.5, "trunk_color": "dark gray", "foliage_color": "magenta", "emissive": true},
	{"archetype": "small_tree", "name": "Silver Birch Sapling", "default_density": 0.009, "scale_min": 0.8, "scale_max": 1.5, "trunk_color": "light gray", "foliage_color": "lime green", "emissive": false},
	{"archetype": "small_tree", "name": "Bioluminescent Stalk", "default_density": 0.010, "scale_min": 0.7, "scale_max": 1.4, "trunk_color": "purple", "foliage_color": "cyan", "emissive": true},
	{"archetype": "shrub", "name": "Woodland Bramble", "default_density": 0.016, "scale_min": 0.7, "scale_max": 1.3, "trunk_color": "brown", "foliage_color": "olive", "emissive": false},
	{"archetype": "shrub", "name": "Glint Bush", "default_density": 0.015, "scale_min": 0.7, "scale_max": 1.3, "trunk_color": "dark slate gray", "foliage_color": "magenta", "emissive": false},
	{"archetype": "fern", "name": "Highland Frond Fern", "default_density": 0.035, "scale_min": 0.8, "scale_max": 1.6, "trunk_color": "brown", "foliage_color": "emerald", "emissive": false},
	{"archetype": "fern", "name": "Neon Spore Fern", "default_density": 0.035, "scale_min": 0.8, "scale_max": 1.6, "trunk_color": "dark violet", "foliage_color": "cyan", "emissive": true},
	{"archetype": "flower", "name": "Clearing Bluebell", "default_density": 0.040, "scale_min": 0.6, "scale_max": 1.2, "trunk_color": "green", "foliage_color": "pink", "emissive": false},
	{"archetype": "flower", "name": "Moon Lotus Bloom", "default_density": 0.040, "scale_min": 0.6, "scale_max": 1.2, "trunk_color": "green", "foliage_color": "cyan", "emissive": true},
	{"archetype": "ground_cover", "name": "Lush Meadow Grass", "default_density": 0.300, "scale_min": 1.2, "scale_max": 2.2, "trunk_color": "green", "foliage_color": "green", "emissive": false},
	{"archetype": "ground_cover", "name": "Crystalline Turf", "default_density": 0.250, "scale_min": 1.2, "scale_max": 2.2, "trunk_color": "cyan", "foliage_color": "cyan", "emissive": false},
	{"archetype": "fallen_log", "name": "Fallen Mossy Timber", "default_density": 0.002, "scale_min": 1.0, "scale_max": 1.8, "trunk_color": "dark brown", "foliage_color": "dark brown", "emissive": false}
]

static func get_summary() -> Dictionary:
	return {
		"landforms": LANDFORM_PROFILES,
		"hydrology": HYDROLOGY_PATTERNS,
		"biomes": BIOME_ARCHETYPES,
		"flora_count": FLORA_SPECIES.size()
	}

