# Following Birds Mod for Farming Simulator 25

## Description

This mod adds immersive wildlife behavior by spawning birds that follow plows while they work. Birds will spawn behind active plows and fly to the freshly worked soil, creating a realistic farming atmosphere.

## Features

- **Dynamic Bird Spawning**: Birds appear behind plows when they start working
- **Natural Flight Patterns**: Birds fly from behind the plow to the worked area
- **Smart Despawning**: Birds scatter and despawn 10 seconds after plowing stops
- **Configurable**: Easy-to-adjust parameters for bird count and behavior
- **Multiplayer Compatible**: Works in multiplayer sessions

## How It Works

1. When you lower a plow and start working, birds spawn around the plowed area at a distance
2. Birds fly/walk into the hotspot area (the freshly worked ground behind the plow)
3. Every 1 second, birds get new random targets within 3m of the hotspot center
4. Birds' previous movement is canceled and they're given a new close target
5. As the plow moves, the hotspot follows (updates every 200ms), keeping birds in the worked area
6. When you stop plowing, birds linger for 10 seconds before naturally despawning

## Configuration

You can easily adjust the behavior by editing `src/PlowBirdHotspot.lua`:

```lua
PlowBirdHotspot.HOTSPOT_RADIUS = 3                 -- Area where birds move around (meters)
PlowBirdHotspot.HOTSPOT_OFFSET_BEHIND = 10         -- Distance behind plow for hotspot
PlowBirdHotspot.MAX_BIRDS = 10                     -- Maximum number of birds
PlowBirdHotspot.BIRDS_PER_SPAWN = 3                -- Birds spawned per group
PlowBirdHotspot.SPAWN_DISTANCE_FROM_HOTSPOT = 20   -- How far away birds initially spawn
PlowBirdHotspot.SPAWN_HEIGHT = 5                   -- Spawn height above ground (meters)
PlowBirdHotspot.UPDATE_INTERVAL = 200              -- How often hotspot updates position (ms)
PlowBirdHotspot.BIRD_TARGET_UPDATE_INTERVAL = 1000 -- How often birds get new targets (ms)
```

And `src/PlowBirdsExtension.lua`:

```lua
PlowBirdsExtension.DESPAWN_DELAY = 10000           -- Despawn delay in milliseconds
PlowBirdsExtension.MIN_WORKING_SPEED = 0.5         -- Minimum speed to trigger birds
```

## Requirements

- Farming Simulator 25
- A map with wildlife enabled (most standard maps)

## Installation

1. Download or clone this repository
2. Place the `FS25_FollowingBirds` folder in your Farming Simulator 25 mods folder:
   - Windows: `Documents/My Games/FarmingSimulator2025/mods/`
3. Start the game and activate the mod in the Mod Hub

## Compatibility

- **Multiplayer**: Fully supported
- **Map Compatibility**: Works with any map that has wildlife enabled
- **Mod Conflicts**: Should be compatible with most mods

## Technical Details

### Architecture

- **PlowBirdHotspot.lua**: Custom hotspot system that follows the plow
- **PlowBirdsExtension.lua**: Hooks into the Plow specialization to manage bird lifecycle
- **main.lua**: Mod initialization and coordination

### How It Extends Farming Simulator

The mod uses Farming Simulator's existing wildlife system and:
1. Hooks into the `Plow` specialization's `onUpdate` and `onDelete` events
2. Creates a mobile hotspot that follows the plow's position
3. Spawns bird instances using the game's wildlife spawning system
4. Manages bird lifecycle based on plow working state

## Future Enhancements

Potential features for future versions:
- Support for other implements (cultivators, seeders, etc.)
- Multiple bird species
- Seasonal bird variations
- Sound effects when birds take flight
- Configuration menu in-game

## Credits

- **Author**: Steve
- **Based on**: Farming Simulator 25 wildlife system reference code

## License

Free to use and modify. Please credit if you use this code in other projects.

## Support

For issues or suggestions, please check the code comments or create an issue in the repository.

## Changelog

### Version 1.0.0
- Initial release
- Birds follow plows while working
- Configurable bird count and spawn behavior
- 10-second despawn delay
- Multiplayer support
