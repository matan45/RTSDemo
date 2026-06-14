# RTS Campaign Hybrid - Game Design Document

Version: 0.1  
Project: RTSDemo / VertexForge  
Document type: Game design bible  
Primary milestone: RTS skirmish first, campaign bridge second

## 1. High Concept

RTS Campaign Hybrid is an original sci-fi colony war game that combines a turn-based territory campaign with real-time tactical battles. The player leads a frontier expedition command on a hostile planet where every region matters: captured territory produces resources, unlocks routes, changes supply, and creates real RTS battles when armies collide.

The strategic layer answers the long-term question: where do we expand, what do we build, which technologies do we prioritize, and which front can we afford to lose? The battle layer answers the immediate question: can we establish a base, harvest resources, manage power, scout under fog of war, produce the right army, and win the fight on the ground?

The design is structurally inspired by classic turn-based empire games and base-building RTS games, but all setting, factions, units, resources, names, and story are original.

## 2. Design Pillars

### 2.1 Campaign Decisions Must Matter In Battle

The campaign is not a menu between unrelated missions. Army composition, region terrain, tech level, supply state, and territory upgrades must directly shape the RTS battle setup.

Examples:

- Attacking from a fortified region grants defensive starting structures or extra supply.
- Fighting in mineral-rich territory creates more harvest points.
- Bringing armor-heavy army stacks allows tanks to deploy at battle start.
- Poor supply delays reinforcements or reduces starting resources.

### 2.2 Battles Must Feed Back Into The War

RTS battles should not reset the board. Surviving units, destroyed assets, captured facilities, and battle objectives should influence the next campaign turns.

Examples:

- A surviving veteran tank returns to the campaign army stack.
- Capturing an enemy relay reveals adjacent campaign regions.
- Destroying infrastructure lowers the region's income for several turns.
- Losing harvesters or factories increases replacement cost.

### 2.3 Simple Economy, Deep Pressure

The v1 economy uses a small number of resources and clear constraints. Depth comes from map control, timing, build order, power management, tech, and attrition, not from many currencies.

### 2.4 Readable Sci-fi Warfare

The game should feel grounded enough for RTS readability but futuristic enough to support colony tech, drones, orbital pressure, unusual terrain, and alien-world hazards. Units should be identifiable at a glance: infantry, engineer, harvester, light vehicle, tank, artillery, aircraft, support, defense.

### 2.5 Build The RTS Core First

The first playable milestone is a complete skirmish loop in `RTSDemo`: base building, resource harvesting, unit production, movement, fog, enemy presence, combat, win/loss, and polished HUD feedback. The campaign layer comes after the battle loop can stand on its own.

## 3. Audience And Player Fantasy

The target player enjoys strategy games where macro decisions create tactical consequences. They want to feel like a commander managing a planetary war, not just clicking through isolated missions.

The fantasy:

- Lead a struggling expedition into contested frontier territory.
- Establish forward bases under pressure.
- Decide which regions, resources, and technologies matter.
- Watch campaign plans become real RTS advantages or problems.
- Win through preparation, scouting, economy, timing, and battlefield control.

## 4. Tone And Setting

### 4.1 Setting Summary

Human colonial powers have reached a mineral-rich frontier planet known as Veyra. The planet is valuable but unstable: magnetic storms disrupt sensors, ancient alien bio-mineral growths reshape terrain, and remote regions are difficult to supply.

Two major forces fight for control:

- The player faction, a formal expedition command trying to secure the colony network.
- The enemy faction, a rival force adapted to aggressive extraction and irregular planetary warfare.

The campaign begins after diplomatic control collapses. Communications are fragmented, regional governors are isolated, and military commanders take control of the war effort.

### 4.2 Visual Tone

The world should mix readable RTS silhouettes with frontier sci-fi:

- Dusty colony outposts, prefabricated military bases, modular power grids.
- Harsh terrain: mesas, cracked flats, mineral fields, storm basins, fungal or crystalline alien growths.
- Practical vehicles with sci-fi upgrades: rail turrets, hover scouts, shield generators, orbital uplinks.
- HUD style: utilitarian military interface with strong icons, clear health/power/resource readouts, and minimap-first battlefield awareness.

### 4.3 Non-goals

- Do not use existing Command & Conquer or Civilization factions, lore, names, logos, assets, or unit identities.
- Do not make the campaign a full historical civilization simulator.
- Do not overload v1 with diplomacy, culture, religion, population happiness, or civilian micromanagement.
- Do not make battles purely scripted missions; they must work as systemic RTS engagements.

## 5. Core Game Structure

The game has two connected modes.

### 5.1 Strategic Campaign Layer

The campaign layer is turn-based and region-driven. The player views a planetary theater map divided into territories. Each turn, factions collect resources, move army stacks, build regional upgrades, research technologies, and resolve contested regions.

Primary campaign verbs:

- Survey adjacent territory.
- Move army stacks.
- Build or upgrade regional bases.
- Recruit strategic forces.
- Research tech.
- Fortify front lines.
- Launch attacks.
- Resolve battles manually or later by autoresolve.

### 5.2 Tactical Battle Layer

The battle layer is real-time. The player controls units and structures directly on a terrain map. A battle may begin from a campaign conflict, a skirmish setup, or a scripted objective.

Primary battle verbs:

- Scout.
- Place buildings.
- Harvest resources.
- Manage power.
- Train units.
- Set rally points.
- Move and group units.
- Attack, defend, flank, retreat.
- Capture or destroy objectives.

### 5.3 Campaign-Battle Bridge

A campaign conflict creates a `BattleSetup`. The battle produces a `BattleResult`.

Inputs from campaign to battle:

- Attacker and defender factions.
- Region terrain and map seed/reference.
- Starting bases or mobile command units.
- Starting resources and power state.
- Army stack units available for deployment.
- Tech unlocks.
- Regional modifiers such as storms, low supply, or fortifications.
- Objective type.

Outputs from battle to campaign:

- Winner and loser.
- Region ownership changes.
- Surviving units returned to army stacks.
- Destroyed units removed or partially recoverable.
- Captured structures or damaged infrastructure.
- Rewards: resources, intel, tech fragments, supply access.
- Campaign events: morale shift, enemy counterattack timer, region unrest.

## 6. Current RTSDemo Foundation

The existing `RTSDemo` project already contains a practical RTS foundation. The GDD should use this as v1 truth rather than inventing a disconnected design.

Observed current systems:

- Startup scene: `scenes/Skirmish_01.vfScene`.
- Playable map bounds: approximately 512 x 512 world units.
- RTS camera and minimap controllers.
- Runtime HUD with resource strip, command bar, command grid, selection panel, build queue area, alerts, and minimap.
- Gold resource and net power display.
- Building placement with grid snap, rotation, slope checks, map bounds, footprint overlap, and fog visibility checks.
- Building definitions for Barracks, Command Center, Refinery, Power Plant, and Factory.
- Building costs, power deltas, health values, icons, prefabs, footprints, sell, upgrade, and command cards.
- Unit definitions for Soldier, Engineer, Tank, and Harvester/Track.
- Production queue with build time and queue UI.
- Rally points and rally markers.
- Harvester loop between refinery and nearest GoldNode.
- Unit selection, drag selection, selected rings, team filtering, and fog vision integration.
- RTSGameplay plugin with Selectable, Selected, Team, Vision components and fog-of-war queries.
- Project-relative asset paths for prefabs, materials, icons, HUD textures, terrain, navmesh, and audio.

## 7. RTS Battle Design

### 7.1 Battle Objective Types

V1 skirmish should support one primary objective:

- Destroy enemy command structure or eliminate enemy production capability.

Campaign battles can later add objective variants:

- Capture relay: hold a neutral structure for a timer.
- Breakthrough: escort units across the map.
- Extraction: harvest or recover a special resource and evacuate.
- Defense: survive waves until reinforcements arrive.
- Raid: destroy infrastructure and retreat before enemy escalation.

### 7.2 Battle Flow

A standard battle should flow through these phases:

1. Deployment: player starts with a Command Center or mobile command equivalent, small starting resources, and a small scout/infantry force.
2. Opening scout: find resources, terrain routes, enemy direction, and neutral objectives.
3. Base setup: place Power Plant, Refinery, Barracks, then Factory or defenses.
4. First pressure: enemy scouts or small squads test the player.
5. Tech choice: invest in economy, vehicles, upgrades, or map control.
6. Midgame conflict: fight over resources and forward positions.
7. Decisive push: destroy enemy base, capture objective, or survive final attack.
8. Results: battle outcome returns to campaign state.

### 7.3 Battle Economy

V1 resource model:

- Gold: primary spendable resource for buildings, units, upgrades, repairs, and campaign conversion.
- Power: net capacity constraint produced by Power Plants and consumed by structures.

Current values from `RTSDemo` should remain the starting balance baseline:

| Building | Cost | Power | Health | Role |
| --- | ---: | ---: | ---: | --- |
| Command Center | 50 | -30 | 1500 | Core base, command functions |
| Barracks | 75 | -20 | 1000 | Infantry production |
| Refinery | 40 | -25 | 800 | Harvester drop-off / economy |
| Power Plant | 60 | +50 | 600 | Power production |
| Factory | 90 | -30 | 1200 | Vehicle production |

Current unit baseline:

| Unit | Cost | Build Time | Role |
| --- | ---: | ---: | --- |
| Soldier | 25 | 3s | Basic infantry, early pressure |
| Engineer | 40 | 5s | Capture/repair/support role |
| Tank | 75 | 8s | Core armored combat unit |
| Harvester / Track | 30 | 4s | Resource collection |

Initial tuning targets:

- A basic base should require one Power Plant before heavy production.
- Refinery plus Harvester should pay back quickly enough to teach economy early.
- Infantry should matter before tanks arrive.
- Tanks should punish unsupported infantry but be expensive enough to delay.
- Power shortage should be visible and eventually affect production speed, radar, defenses, or build availability.

### 7.4 Buildings

#### Command Center

Role: central base structure, territory anchor, builder authority.  
Battle functions: unlock base construction, provide radar/minimap support, produce builders or command abilities later.  
Campaign meaning: represents a deployed command post or regional HQ.

V1 commands:

- Sell.
- Upgrade.
- Rally or base command ability placeholder.
- Build access through HUD slots.

Future upgrades:

- Tactical uplink: reveals temporary fog area.
- Drop beacon: calls campaign reserve units.
- Shield grid: temporary base damage reduction.

#### Barracks

Role: infantry production.  
Battle functions: train Soldier and Engineer.  
Campaign meaning: improves regional garrison and low-cost defense.

V1 commands:

- Sell.
- Upgrade.
- Rally.
- Soldier.
- Engineer.

Future upgrades:

- Combat medkits.
- Engineer capture kit.
- Infantry armor.

#### Refinery

Role: economy structure.  
Battle functions: spawns or supports Harvester/Track resource loops.  
Campaign meaning: improves region income if preserved.

V1 commands:

- Sell.
- Upgrade.
- Rally.
- Track / Harvester.

Future upgrades:

- Faster unload.
- Increased harvester capacity.
- Hardened storage.

#### Power Plant

Role: power production.  
Battle functions: supports production, radar, and future defenses.  
Campaign meaning: regional infrastructure.

V1 commands:

- Sell.
- Upgrade.

Future upgrades:

- Overcharge: temporary extra power at damage risk.
- Stabilized grid: lowers enemy sabotage effect.

#### Factory

Role: vehicle production.  
Battle functions: train Tank and later advanced vehicles.  
Campaign meaning: enables armored army recruitment in the region.

V1 commands:

- Sell.
- Upgrade.
- Rally.
- Tank.
- Harvester or light vehicle depending on final roster.

Future upgrades:

- Reinforced plating.
- Faster assembly.
- Specialized chassis unlocks.

### 7.5 Units

#### Soldier

Role: basic infantry.  
Strengths: cheap, fast to train, good for scouting, early defense, garrison/capture support later.  
Weaknesses: vulnerable to vehicles and area damage.

Design notes:

- Should remain useful through upgrades and numbers.
- Needs clear selection silhouette and readable weapon feedback.

#### Engineer

Role: utility infantry.  
Strengths: repairs, captures neutral or damaged structures, interacts with objectives.  
Weaknesses: low combat power, high tactical value.

V1 minimum:

- Can be produced and moved.

Future required abilities:

- Capture neutral tech structures.
- Repair friendly buildings.
- Restore disabled power nodes.
- Claim campaign objective structures during battle.

#### Tank

Role: core armored attacker.  
Strengths: durable, strong against structures and light units.  
Weaknesses: cost, build time, vulnerable to specialized anti-armor and poor scouting.

Design notes:

- Tank should be the first major power spike.
- Needs turret/fire behavior and readable target priority.

#### Harvester / Track

Role: economy vehicle.  
Strengths: enables income, high strategic value.  
Weaknesses: vulnerable, creates harassment targets.

Design notes:

- Current loop between Refinery and GoldNode is correct for v1.
- Harvester attacks should be a key enemy pressure pattern.

### 7.6 Combat Model

V1 combat should be simple and deterministic enough to debug:

- Units have health, armor class, weapon damage, range, reload time, move speed, sight radius, and target filters.
- Attacks require line of sight and valid target range.
- Projectile or hitscan choice can be per weapon, but v1 may use simple direct damage first.
- Death removes unit, selection marker, fog vision source, and campaign survivor entry.

Recommended armor classes:

- Infantry.
- LightVehicle.
- HeavyVehicle.
- Structure.
- Air, later.

Recommended damage types:

- Ballistic.
- Explosive.
- Energy.
- Siege.

### 7.7 Fog And Scouting

Fog of war is central to both battle and campaign identity.

Battle rules:

- Player can only place buildings in visible terrain.
- Units and buildings provide Vision components.
- Explored but not visible terrain should retain memory but hide enemy movement.
- Minimap should reflect visible/intel state.

Campaign bridge:

- Scout units or captured relays reveal adjacent campaign regions.
- Sensor tech improves starting battle intel.
- Storm regions reduce sight radius or radar reliability.

### 7.8 Battle Win And Loss

V1 win condition:

- Destroy enemy Command Center or all enemy production structures.

V1 loss condition:

- Player Command Center destroyed and no replacement command unit exists.

Future campaign battle outcomes:

- Decisive victory: capture region and gain bonus salvage.
- Costly victory: capture region but lose infrastructure value.
- Withdrawal: keep some army units but fail objective.
- Defeat: lose region, surviving units retreat if route exists.

## 8. Strategic Campaign Design

### 8.1 Campaign Map

The campaign map is a planetary theater divided into regions. Regions are large enough to matter strategically and small enough that front lines are readable.

Region properties:

- Owner faction.
- Terrain tags.
- Resource output.
- Infrastructure level.
- Fortification level.
- Supply connection.
- Intel state.
- Battle map seed or scene reference.
- Special sites.

Recommended terrain tags:

- Plains: balanced base building and vehicle movement.
- Highlands: chokepoints and defensive bonuses.
- Basin: rich resources but exposed base locations.
- Storm Zone: reduced vision/radar.
- Ruins: neutral tech structures and capture objectives.
- Spore/Crystal Field: hazardous but valuable.

### 8.2 Turn Structure

Each campaign turn follows a stable order:

1. Start of turn income and upkeep.
2. Event phase: storms, enemy moves, alerts.
3. Research progress.
4. Construction/recruitment completion.
5. Player orders: move armies, build, recruit, research, fortify, attack.
6. Enemy orders.
7. Conflict detection.
8. Battle resolution.
9. End turn state update.

### 8.3 Campaign Resources

Recommended campaign resources:

- Credits: strategic economy used for recruitment, construction, repairs.
- Alloy: advanced material used for vehicles, defenses, and upgrades.
- Intel: unlocks enemy region info, battle previews, and special operations.
- Supply: limits army projection and reinforcement speed.

V1 campaign prototype can start with Credits and Supply only.

### 8.4 Regions And Bases

Each controlled region may support one base level:

- Outpost: basic control, low income, minimal defense.
- Base: recruitment, repairs, better supply.
- Stronghold: fortification, advanced production, defensive battle advantage.

Base upgrades:

- Power Grid: improves battle starting power or campaign output.
- Refinery Network: increases income and adds battle resource nodes.
- Sensor Relay: reveals adjacent territory and improves minimap/radar.
- Vehicle Depot: enables tanks and heavy units from this region.
- Defense Line: adds turrets, walls, or starting defenders in battle.

### 8.5 Army Stacks

Army stacks are campaign-level forces that move between adjacent regions.

Rules:

- Each stack has faction, location, unit counts, supply need, veterancy summary, and commander/stance later.
- Stacks can attack adjacent enemy regions.
- Multiple friendly stacks may join a battle if adjacent and supplied.
- Defeated stacks retreat only through friendly connected regions.

Battle deployment:

- Army units can appear as starting units, reinforcements, or build unlocks.
- Campaign should not require exact one-to-one persistence for every infantry unit in early versions, but vehicles and veteran units should persist when possible.

### 8.6 Research And Tech

Research exists on the campaign layer and unlocks battle options.

Tech categories:

- Economy: harvesting, refinery output, build speed.
- Power: better plants, grid efficiency, emergency power.
- Infantry: armor, weapons, engineer tools.
- Vehicles: tank upgrades, new chassis, repair drones.
- Sensors: fog, radar, campaign intel.
- Command: reinforcements, orbital scan, emergency drops.

Tech should modify battle options clearly rather than adding invisible bonuses only.

Examples:

- Field Fabrication: Barracks infantry build 15% faster.
- Stabilized Reactor: Power Plants produce +10 power.
- Composite Armor: Tanks gain more health.
- Deep Scanner: start battles with a larger visible area.
- Relay Hijack Kit: Engineers capture neutral relays faster.

### 8.7 Campaign Victory Conditions

Possible campaign victory conditions:

- Control the planetary capital and all adjacent supply corridors.
- Destroy enemy main command network.
- Capture enough extraction zones to force enemy withdrawal.
- Complete a final operation unlocked by territory and tech requirements.

V1 campaign prototype victory:

- Capture a fixed number of key regions, then win one final battle.

## 9. Factions

### 9.1 Player Faction: Colonial Expedition Command

Working name: Colonial Expedition Command, CEC.

Fantasy:

A disciplined frontier military-logistics force trying to stabilize Veyra and protect the colony network. CEC uses balanced combined arms, modular bases, reliable power, and strong engineering.

Battle identity:

- Balanced economy.
- Durable structures.
- Strong engineers and repair options.
- Good radar and defensive tools.
- Medium-cost vehicles.

Campaign identity:

- Strong supply lines.
- Better fortifications.
- Reliable region development.
- Slower to expand without infrastructure.

Core roster:

- Soldier: rifle infantry.
- Engineer: repair/capture utility.
- Harvester/Track: resource vehicle.
- Tank: main battle vehicle.
- Future Scout Rover: fast recon.
- Future Artillery Walker: siege.
- Future Shield Truck: support.

Core buildings:

- Command Center.
- Power Plant.
- Refinery.
- Barracks.
- Factory.
- Future Radar Relay.
- Future Defense Turret.
- Future Tech Lab.

Weaknesses:

- Predictable tech path.
- Needs power stability.
- Strong when prepared, weaker when cut off.

### 9.2 Enemy Faction: Helix Extraction Combine

Working name: Helix Extraction Combine, HEC.

Fantasy:

A rival corporate-military force that treats the planet as a resource engine. HEC uses aggressive extraction, disposable forward bases, fast raids, and unstable high-output technology adapted to Veyra's hostile environment.

Battle identity:

- Faster early aggression.
- Cheaper light vehicles and raiders.
- Risky overcharged power and extraction bonuses.
- Weaker static durability but stronger map pressure.
- Harvester harassment and flanking.

Campaign identity:

- Expands quickly into resource regions.
- Can strip-mine territories for short-term income while damaging long-term value.
- More likely to raid than fortify.
- Suffers when supply hubs are captured.

Core enemy roster:

- Enforcer: basic infantry.
- Saboteur: utility/capture/disable unit.
- Extractor Track: harvester equivalent.
- Breaker Tank: aggressive armor.
- Future Raider Bike: fast harassment.
- Future Siege Crawler: mobile artillery.
- Future Drone Swarm: disposable scouts/attackers.

Core enemy buildings:

- Operations Core.
- Overdrive Reactor.
- Extractor Plant.
- Troop Dock.
- Assembly Yard.
- Future Jammer Tower.
- Future Shredder Turret.

Weaknesses:

- Less durable infrastructure.
- Risk/reward power mechanics can backfire.
- Needs map control to stay ahead.

## 10. AI Design

### 10.1 Campaign AI

The campaign AI should create pressure without requiring perfect grand strategy.

AI goals:

- Expand toward valuable regions.
- Protect supply hubs.
- Attack weak front lines.
- Raid high-income regions.
- Fortify when threatened.
- Escalate based on player success.

Campaign AI decision inputs:

- Region value.
- Distance from supply.
- Enemy strength estimate.
- Fortification level.
- Recent losses.
- Strategic personality.

V1 campaign AI can be rule-based:

- If adjacent player region is weak, attack.
- If own key region is exposed, fortify.
- If resource region is neutral, expand.
- If behind economically, raid income region.

### 10.2 RTS Battle AI

Battle AI needs tactical clarity before high sophistication.

V1 enemy AI behaviors:

- Build a basic base from a script or prebuilt layout.
- Produce harvesters and basic units.
- Send scout units early.
- Attack harvesters when found.
- Launch timed attack waves.
- Rebuild key production if resources allow.
- Defend command structure.

Later AI improvements:

- Dynamic build order.
- Threat response groups.
- Expansion bases.
- Tech choice based on player composition.
- Retreat and regroup.
- Objective-specific behavior.

## 11. User Interface And UX

### 11.1 RTS HUD

The current HUD direction is correct: bottom command area, resource strip, minimap, selection panel, command grid, alerts, and build queue.

Required RTS HUD information:

- Gold.
- Net power.
- Selected unit/building name.
- Health bar.
- Icon/portrait.
- Command card.
- Production queue and progress.
- Alert messages.
- Minimap.
- Fog/intel visibility.

Important UX rules:

- Invalid placement must clearly show why: blocked, no vision, no money, bad slope, out of bounds, no power if implemented.
- Command buttons should use icons with tooltips when art exists; text labels are acceptable during prototype.
- Alerts should be short and actionable.
- Selection behavior should match RTS expectations: click, drag select, shift add/remove, escape clear.
- Rally points should show visible confirmation.

### 11.2 Campaign UI

Campaign UI should prioritize map readability.

Required campaign UI panels:

- Region info.
- Army stack info.
- Turn controls.
- Resource/income summary.
- Research panel.
- Construction/recruitment panel.
- Battle preview panel.
- Event/alert log.

Battle preview should show:

- Attacker and defender.
- Region terrain.
- Known enemy strength estimate.
- Player participating stacks.
- Starting resource/power modifiers.
- Objectives.
- Manual battle button.
- Autoresolve button later.

## 12. Save And Persistence

### 12.1 Campaign Save

Campaign saves must store:

- Current turn.
- Region ownership and upgrades.
- Army stacks and unit counts.
- Research progress and completed tech.
- Global resources.
- Revealed intel.
- Active events.
- Pending battles.

### 12.2 Battle Save

Full mid-battle save can be deferred. For early versions, save before entering a battle and after battle result.

Minimum persistence flow:

1. Campaign state creates `BattleSetup`.
2. Battle runs as a separate scene/session.
3. Battle emits `BattleResult`.
4. Campaign applies result and saves.

Later battle save support should capture entities, health, queues, resources, fog state, AI state, and active objectives.

## 13. Implementation-facing Data Contracts

These are design contracts, not required runtime APIs yet. They describe the data shapes future implementation should support.

### 13.1 FactionDef

```json
{
  "id": "cec",
  "displayName": "Colonial Expedition Command",
  "techStyle": "balanced_modular",
  "battleRoster": ["soldier", "engineer", "harvester", "tank"],
  "buildingRoster": ["command_center", "power_plant", "refinery", "barracks", "factory"],
  "campaignBehavior": {
    "expansion": "steady",
    "fortification": "high",
    "raidPreference": "low"
  }
}
```

Required fields:

- `id` stable save key.
- `displayName` UI name.
- `techStyle` balance identity.
- `battleRoster` available unit ids.
- `buildingRoster` available building ids.
- `campaignBehavior` AI/balance hints.

### 13.2 RegionDef

```json
{
  "id": "basin_03",
  "displayName": "Kavren Basin",
  "ownerFactionId": "cec",
  "terrainTags": ["basin", "rich_resources"],
  "resourceOutput": { "credits": 80, "alloy": 15 },
  "infrastructureLevel": 1,
  "fortificationLevel": 0,
  "supplyConnected": true,
  "battleMap": "scenes/Skirmish_01.vfScene",
  "battleSeed": 10342,
  "specialSites": ["relay_tower"]
}
```

Required fields:

- Region identity and owner.
- Terrain tags for battle modifiers.
- Resource output.
- Infrastructure and fortification values.
- Supply connection state.
- Battle scene path or procedural seed.
- Optional special sites.

### 13.3 ArmyStack

```json
{
  "id": "army_cec_01",
  "factionId": "cec",
  "regionId": "basin_03",
  "units": [
    { "unitId": "soldier", "count": 12, "veterancy": 0 },
    { "unitId": "tank", "count": 3, "veterancy": 1 }
  ],
  "supplyNeed": 4,
  "stance": "balanced"
}
```

Required fields:

- Stack id.
- Faction id.
- Current region.
- Unit counts and optional veterancy.
- Supply need.
- Stance for AI/autoresolve later.

### 13.4 BattleSetup

```json
{
  "battleId": "battle_0007",
  "regionId": "basin_03",
  "scenePath": "scenes/Skirmish_01.vfScene",
  "attackerFactionId": "hec",
  "defenderFactionId": "cec",
  "attackerStacks": ["army_hec_02"],
  "defenderStacks": ["army_cec_01"],
  "startingGold": { "attacker": 120, "defender": 100 },
  "startingPower": { "attacker": 0, "defender": 0 },
  "techUnlocks": { "cec": ["stabilized_reactor"], "hec": [] },
  "objectives": ["destroy_enemy_command"],
  "modifiers": ["rich_resources", "storm_low_vision"]
}
```

Required fields:

- Battle id and region id.
- Scene path or map seed.
- Attacker/defender factions.
- Participating army stacks.
- Starting resources and power.
- Tech unlocks.
- Objectives.
- Region/campaign modifiers.

### 13.5 BattleResult

```json
{
  "battleId": "battle_0007",
  "winnerFactionId": "cec",
  "outcome": "decisive_victory",
  "capturedRegion": true,
  "survivingUnits": {
    "cec": [
      { "unitId": "soldier", "count": 8, "veterancy": 0 },
      { "unitId": "tank", "count": 2, "veterancy": 1 }
    ]
  },
  "destroyedInfrastructure": 1,
  "rewards": { "credits": 120, "intel": 10 },
  "campaignEffects": ["reveal_adjacent_region"]
}
```

Required fields:

- Battle id.
- Winner faction.
- Outcome rating.
- Region ownership result.
- Surviving units.
- Infrastructure damage.
- Rewards.
- Campaign effects.

### 13.6 TechDef

```json
{
  "id": "stabilized_reactor",
  "displayName": "Stabilized Reactor",
  "category": "power",
  "cost": { "credits": 150, "intel": 5 },
  "prerequisites": [],
  "battleEffects": [
    { "target": "power_plant", "stat": "power", "op": "add", "value": 10 }
  ],
  "campaignEffects": [
    { "target": "region", "stat": "powerGridOutput", "op": "add", "value": 1 }
  ]
}
```

Required fields:

- Tech id and display name.
- Category.
- Cost.
- Prerequisites.
- Battle effects.
- Campaign effects.

## 14. VertexForge Technical Direction

The design should lean into systems already present in VertexForge and `RTSDemo`.

Use existing foundations:

- mType scripts for gameplay controllers and UI logic.
- `.vfScene` scenes for battle maps.
- `.vfPrefab` assets for units, buildings, UI templates, and authored colliders.
- Project-relative asset paths for portability.
- Runtime UI for HUD, tooltips, modal windows, list views, and themed panels.
- RTSGameplay plugin for Selectable, Selected, Team, Vision, and fog-of-war queries.
- Terrain and physics picking for placement.
- Navmesh assets for future movement/pathfinding.
- Plugin architecture for native ECS components and performance-critical RTS systems.

Recommended future native/plugin components:

- `Health`: max/current health, armor class.
- `Weapon`: range, damage, reload, damage type, target filters.
- `Mover`: move speed, turn speed, path target.
- `Production`: queue, rally point, allowed unit ids.
- `ResourceNode`: amount, gather rate, depleted state.
- `ResourceCarrier`: carried amount, capacity, home refinery.
- `CommandIdentity`: faction, unit/building id, display name, icon.
- `CampaignLink`: source stack id, persistence flags.

Keep high-level campaign data in script/JSON first. Move to native systems only when scale or performance requires it.

## 15. Content Pipeline

### 15.1 Units And Buildings

Each gameplay entity should eventually have:

- Stable design id.
- Prefab path.
- Icon path.
- Display name.
- Faction availability.
- Cost and build time.
- Health and armor.
- Power production/consumption if building.
- Footprint if building.
- Vision radius.
- Weapon definitions if combat-capable.
- Campaign recruitment rules.

### 15.2 Battle Maps

Each map should define:

- Bounds.
- Starting locations.
- Resource node positions.
- Terrain tags.
- Neutral objectives.
- AI build areas.
- Chokepoints and routes.
- Minimap setup.
- Lighting/weather variant.

### 15.3 Campaign Regions

Each campaign region should reference or generate battle content:

- Region terrain tags map to battle scene variant.
- Resource output maps to resource node density.
- Fortification level maps to starting defenses.
- Infrastructure maps to starting buildings or objectives.
- Supply state maps to starting resource and reinforcement rules.

## 16. Balance Principles

### 16.1 RTS Balance

- Economy harassment should hurt but not instantly decide every game.
- Power should matter without becoming constant punishment.
- Infantry should be relevant before vehicles and useful later with support.
- Tanks should be strong but scoutable and counterable.
- Engineers should create high-value tactical choices.
- Fog should reward scouting, not blind guessing.
- Production queues should create readable timing windows.

### 16.2 Campaign Balance

- Capturing regions should feel valuable but defending them should matter.
- The player should not be able to snowball without supply and defense pressure.
- Enemy raids should create interesting response choices, not random punishment.
- Strategic tech should unlock new play patterns rather than only stat inflation.
- Autoresolve, when added, must not become better than manual battle by default.

## 17. Milestone Roadmap

### Milestone 1: RTS Skirmish Complete

Goal: a full standalone battle loop in `RTSDemo`.

Required:

- Complete unit movement orders.
- Combat, health, death, target acquisition.
- Enemy base or enemy wave AI.
- Win/loss conditions.
- Harvester/resource loop polished.
- Power shortage gameplay effect.
- Build queue and production feedback.
- Basic audio/visual combat feedback.
- One playable skirmish map.

Success criteria:

- Player can start, build an economy, train units, fight enemy units, destroy the enemy base, and reach a victory screen/state.

### Milestone 2: RTS Content Expansion

Goal: make the skirmish loop strategically interesting.

Required:

- Add at least one anti-armor or support unit.
- Add one defensive structure.
- Add neutral capturable objective.
- Add first pass upgrades.
- Improve enemy AI attacks and defense.
- Add battlefield result summary.

Success criteria:

- Multiple viable build orders exist and scouting changes decisions.

### Milestone 3: Campaign Shell

Goal: create a turn-based territory map without manual battle dependency.

Required:

- Region map UI.
- Region ownership.
- Turn flow.
- Income.
- Army stack movement.
- Basic recruitment.
- Basic research.
- Simple AI expansion/attack.
- Placeholder autoresolve.

Success criteria:

- Player can play several turns, move armies, capture regions, and see front lines shift.

### Milestone 4: Campaign-Battle Bridge

Goal: connect campaign conflicts to RTS battles.

Required:

- Generate `BattleSetup` from campaign state.
- Launch RTS battle scene with setup values.
- Apply `BattleResult` back to campaign.
- Persist campaign before/after battles.
- Show battle preview and result screen.

Success criteria:

- A campaign army attacks a region, launches an RTS battle, wins or loses, and the campaign map updates correctly.

### Milestone 5: First Campaign Arc

Goal: playable mini-campaign.

Required:

- 8-12 regions.
- 2 factions.
- 4-6 techs.
- 3 map variants.
- Basic story/event text.
- Final objective region.
- Save/load campaign.

Success criteria:

- Player can complete a short campaign from first region to final battle.

## 18. Open Design Questions

These are intentionally left open until implementation proves what the engine and gameplay need.

- Should battle maps be mostly authored scenes, procedural variants, or authored scenes with procedural resource/objective placement?
- Should all surviving units persist exactly, or should infantry be abstracted into counts while vehicles persist more exactly?
- Should power shortage disable buildings, slow production, disable radar, or all of these by severity?
- Should engineers capture enemy buildings, neutral objectives only, or both?
- Should the enemy faction be fully playable later or remain campaign AI only?
- How much campaign diplomacy is useful before it distracts from territory war?

## 19. Glossary

- Campaign layer: turn-based strategic territory map.
- Battle layer: real-time RTS combat scene.
- Region: a territory on the campaign map.
- Army stack: campaign force that moves between regions.
- BattleSetup: data package that starts a tactical battle.
- BattleResult: data package returned from battle to campaign.
- Tech unlock: campaign research that affects battle or strategic options.
- Supply: campaign constraint controlling how far and how effectively armies operate.
- Fog of war: battle visibility system where units/buildings reveal terrain.

## 20. Immediate Next Design Tasks

After this document is accepted, the next design tasks should be:

1. Write a one-page RTS skirmish MVP checklist from Milestone 1.
2. Define exact v1 combat stats for Soldier, Engineer, Tank, Harvester, and each building.
3. Define enemy base/wave AI behavior for `Skirmish_01`.
4. Decide power shortage rules.
5. Draft the first 8-region campaign map and region list.
