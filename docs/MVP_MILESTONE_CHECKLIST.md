# MVP Milestone Checklist

Project: RTSDemo / VertexForge  
Companion document: `GAME_DESIGN_DOCUMENT.md`  
Purpose: implementation tracker for the first playable RTS/campaign hybrid path

## How To Use This Checklist

- Treat each milestone as shippable only when its acceptance criteria are met in a playable build.
- Keep prototype shortcuts visible by adding notes under the relevant task instead of silently accepting incomplete behavior.
- Prefer completing Milestone 1 before building campaign systems, unless a small campaign data stub is needed to test the bridge.
- A checked task should mean the feature works in the game, not only that a script or asset exists.

## Milestone 1: RTS Skirmish Complete

Goal: a complete standalone real-time battle loop in `RTSDemo`.

### Core Gameplay

- [ ] Player can start `scenes/Skirmish_01.vfScene` and immediately control the RTS camera.
- [ ] Player can select units with click selection.
- [ ] Player can drag-select multiple units.
- [ ] Player can move selected units to a clicked ground location.
- [ ] Move orders respect terrain height and do not leave units stuck in common cases.
- [ ] Stop command cancels current unit movement or attack order.
- [ ] Attack command or right-click enemy order makes units engage enemies.
- [ ] Attack-move command moves units while engaging enemies encountered on the path.
- [ ] Hold command prevents selected units from chasing too far.
- [ ] Units can acquire nearby valid enemy targets automatically.
- [ ] Units can deal damage to enemy units and buildings.
- [ ] Units and buildings have health values visible through selection or debug UI.
- [ ] Units and buildings die or are destroyed at zero health.
- [ ] Destroyed units are removed from selection groups and vision sources.
- [ ] Destroyed buildings are removed from selection, footprint blocking, and command logic.

### Base Building And Economy

- [ ] Player can place Command Center, Barracks, Refinery, Power Plant, and Factory.
- [ ] Placement keeps existing grid snap, rotation, footprint, slope, bounds, and fog checks working.
- [ ] Invalid placement gives clear feedback through ghost tint and/or alert text.
- [ ] Building placement spends gold only on successful placement.
- [ ] Build slots are disabled or clearly rejected when unaffordable.
- [ ] Net power updates correctly when buildings are placed, sold, or upgraded.
- [ ] Power shortage has a gameplay effect, not only a red number.
- [ ] Refinery can produce or support a Harvester/Track.
- [ ] Harvester/Track travels to a GoldNode, mines, returns, and deposits gold.
- [ ] Harvester loop survives several trips without drifting, duplicating deposits, or stopping unexpectedly.
- [ ] Selling a building refunds the expected amount and frees its placement footprint.
- [ ] Upgrading a building applies its intended v1 benefit and cannot be repeated unless designed.

### Production

- [ ] Barracks can queue Soldier.
- [ ] Barracks can queue Engineer.
- [ ] Factory can queue Tank.
- [ ] Refinery or Factory can queue Harvester/Track according to final v1 command card.
- [ ] Production queue displays unit icon, name or type, and progress.
- [ ] Queue advances over time and spawns the unit when complete.
- [ ] Spawned units receive Selectable, Team, and Vision components as appropriate.
- [ ] Spawned units appear at a valid location near the producing building.
- [ ] Rally point can be set on valid ground.
- [ ] Newly produced units move toward the rally point.
- [ ] Queue handles full-queue, insufficient gold, and destroyed-producer cases safely.

### Enemy And Combat Scenario

- [ ] Enemy has at least one visible base or command structure.
- [ ] Enemy has selectable/readable Team ownership for combat targeting.
- [ ] Enemy produces or receives units through a simple AI script.
- [ ] Enemy sends early scout or pressure units.
- [ ] Enemy attacks player harvesters when they are found.
- [ ] Enemy launches at least one timed attack wave.
- [ ] Enemy base defends itself with units or defensive structures.
- [ ] Enemy stops functioning when its command/production structures are destroyed.

### HUD, Feedback, And UX

- [ ] HUD shows current gold.
- [ ] HUD shows net power and shortage state.
- [ ] HUD shows selected building name, icon, health, and status.
- [ ] HUD shows selected unit name/type, icon, health, and status where supported.
- [ ] Command card changes based on selected building/unit.
- [ ] Alerts fire for key failures: insufficient gold, invalid placement, no producer, queue full.
- [ ] Minimap renders the battle area.
- [ ] Minimap click moves the camera.
- [ ] Fog of war hides unexplored or unseen enemy activity.
- [ ] Player buildings and units reveal terrain through Vision.
- [ ] Combat has basic visual and audio feedback for firing, impact, damage, and destruction.

### Win, Loss, And Result

- [ ] Player wins by destroying enemy command structure or enemy production capability.
- [ ] Player loses when Command Center is destroyed and no replacement command option exists.
- [ ] Win/loss state stops active combat logic cleanly.
- [ ] Result screen or result HUD message clearly shows victory or defeat.
- [ ] Player can restart or exit the skirmish after result.

### Acceptance Criteria

- [ ] From a fresh start, the player can build an economy, train units, fight enemy units, destroy the enemy base, and reach a victory state.
- [ ] From a fresh start, enemy pressure can destroy the player's base and trigger a defeat state.
- [ ] No core loop step requires editor intervention or manual entity spawning.
- [ ] One complete playthrough can be recorded without obvious blocking bugs.

## Milestone 2: RTS Content Expansion

Goal: make the skirmish loop strategically interesting and replayable.

### New Content

- [ ] Add at least one anti-armor unit or weapon role.
- [ ] Add at least one support unit or support ability.
- [ ] Add at least one defensive structure.
- [ ] Add at least one neutral capturable objective.
- [ ] Add at least one new map-control incentive beyond the main base and GoldNodes.
- [ ] Add final v1 icons for new units, structures, and objectives.
- [ ] Add final v1 selection names and tooltips for all new content.

### Upgrades And Tech Hooks

- [ ] Add first-pass building upgrades with clear effects.
- [ ] Add first-pass unit upgrades with clear effects.
- [ ] Add upgrade costs and prerequisites.
- [ ] Upgrade buttons show unavailable, unaffordable, and completed states.
- [ ] Upgrades affect gameplay stats, not only UI text.
- [ ] Upgrade effects are data-driven enough to connect to campaign `TechDef` later.

### Better Battle AI

- [ ] Enemy chooses between at least two attack wave compositions.
- [ ] Enemy reacts to player harassment by defending harvesters or key structures.
- [ ] Enemy rebuilds at least one destroyed economy or production building when possible.
- [ ] Enemy expands or contests a neutral objective.
- [ ] Enemy attack timing scales with difficulty or elapsed time.
- [ ] Enemy does not continue issuing orders to destroyed units/buildings.

### Tactical Depth

- [ ] Scouting reveals useful information before attacks arrive.
- [ ] Harvester harassment is possible but counterable.
- [ ] Defensive play is viable but does not stall forever.
- [ ] Infantry, vehicles, engineers, and harvesters all have distinct battlefield roles.
- [ ] At least two viable player build orders exist.
- [ ] Map layout supports at least two attack routes or meaningful chokepoints.

### Battle Summary

- [ ] End-of-battle summary shows winner.
- [ ] Summary shows units produced.
- [ ] Summary shows units lost.
- [ ] Summary shows buildings destroyed.
- [ ] Summary shows resources harvested/spent.
- [ ] Summary data is structured so it can become `BattleResult` later.

### Acceptance Criteria

- [ ] Replaying the same skirmish supports different strategies.
- [ ] Scouting changes player decisions.
- [ ] Neutral objectives or upgrades create a reason to leave the starting base.
- [ ] Enemy behavior creates pressure without depending entirely on scripted single-use events.

## Milestone 3: Campaign Shell

Goal: create a playable turn-based territory layer before connecting manual RTS battles.

### Campaign Map

- [ ] Create a campaign screen or scene.
- [ ] Display 8-12 prototype regions.
- [ ] Show region ownership by faction.
- [ ] Show selected region details.
- [ ] Show adjacency or legal movement routes.
- [ ] Show region terrain tags.
- [ ] Show region income values.
- [ ] Show region infrastructure and fortification level.
- [ ] Show region supply-connected state.

### Turn Loop

- [ ] Player can start a new campaign.
- [ ] Campaign tracks current turn number.
- [ ] End Turn advances the campaign state once.
- [ ] Income is collected at start of turn.
- [ ] Recruitment and construction timers progress.
- [ ] Research progress advances each turn.
- [ ] Events or alerts are shown to the player.
- [ ] Player cannot issue invalid actions after ending the turn.

### Army Stacks

- [ ] Player can create or receive at least one army stack.
- [ ] Enemy can create or receive at least one army stack.
- [ ] Army stack displays faction, region, units, and supply need.
- [ ] Player can move army stack to adjacent legal region.
- [ ] Movement respects blocked or enemy-controlled rules chosen for v1.
- [ ] Multiple stacks in a contested region trigger a conflict state.
- [ ] Defeated stacks can be removed or retreated by placeholder logic.

### Recruitment, Construction, And Research

- [ ] Player can recruit basic strategic units into a region or stack.
- [ ] Player can build or upgrade regional infrastructure.
- [ ] Player can build or upgrade regional fortification.
- [ ] Player can start one research item.
- [ ] Completed research unlocks at least one visible benefit.
- [ ] Costs are paid and rejected when unaffordable.
- [ ] UI shows pending recruitment, construction, and research.

### Campaign AI

- [ ] Enemy expands into neutral or valuable regions.
- [ ] Enemy attacks weak adjacent player regions.
- [ ] Enemy fortifies a threatened region.
- [ ] Enemy choices are visible through alerts or changed map state.
- [ ] Enemy behavior can be tuned from simple weights or constants.

### Placeholder Battle Resolution

- [ ] Conflict can be resolved through placeholder autoresolve.
- [ ] Autoresolve considers at least unit strength and fortification.
- [ ] Autoresolve changes region ownership when appropriate.
- [ ] Autoresolve applies unit losses.
- [ ] Autoresolve produces a readable result summary.

### Acceptance Criteria

- [ ] Player can play several turns without entering RTS battle.
- [ ] Armies move, regions change ownership, income changes, and front lines shift.
- [ ] The campaign state can be saved or serialized in a prototype format.
- [ ] The shell is fun enough to reveal obvious missing strategy decisions.

## Milestone 4: Campaign-Battle Bridge

Goal: connect campaign conflicts to playable RTS battles and apply results back to the campaign.

### BattleSetup Generation

- [ ] Campaign conflict creates a unique `BattleSetup`.
- [ ] `BattleSetup` includes battle id and region id.
- [ ] `BattleSetup` includes attacker and defender faction ids.
- [ ] `BattleSetup` includes participating army stack ids.
- [ ] `BattleSetup` includes scene path or battle map seed.
- [ ] `BattleSetup` includes starting gold and starting power.
- [ ] `BattleSetup` includes tech unlocks for each faction.
- [ ] `BattleSetup` includes objective list.
- [ ] `BattleSetup` includes region/campaign modifiers.
- [ ] Generated setup can be inspected in logs or debug UI.

### Battle Launch

- [ ] Player can choose Manual Battle from campaign conflict preview.
- [ ] Battle scene loads using `BattleSetup`.
- [ ] Player faction, starting resources, and starting units/buildings match setup.
- [ ] Enemy faction, starting resources, and starting units/buildings match setup.
- [ ] Region terrain or map reference affects the loaded battle.
- [ ] Tech unlocks affect available units, buildings, upgrades, or stats.
- [ ] Campaign modifiers affect battle conditions.
- [ ] Cancel/back behavior returns safely before battle starts.

### BattleResult Collection

- [ ] Battle emits unique `BattleResult` for the active battle id.
- [ ] Result includes winner faction.
- [ ] Result includes outcome rating.
- [ ] Result includes surviving unit summary.
- [ ] Result includes destroyed unit/building summary.
- [ ] Result includes infrastructure damage.
- [ ] Result includes rewards.
- [ ] Result includes campaign effects.
- [ ] Result is logged or visible in result UI for debugging.

### Apply Result To Campaign

- [ ] Campaign reloads or resumes after battle ends.
- [ ] Correct region ownership update is applied.
- [ ] Army stack losses are applied.
- [ ] Surviving units are returned to the correct stack or region.
- [ ] Rewards are added to campaign resources.
- [ ] Infrastructure damage affects the region.
- [ ] Campaign effects such as reveal adjacent region are applied.
- [ ] Campaign saves after result application.

### Preview And UX

- [ ] Campaign battle preview shows attacker, defender, region, known strength, and objective.
- [ ] Preview shows expected starting resources or major modifiers.
- [ ] Result screen explains what changed on the campaign map.
- [ ] Player can continue the next campaign turn after returning.

### Acceptance Criteria

- [ ] A campaign army attacks a region, launches an RTS battle, wins or loses, and returns to an updated campaign map.
- [ ] The same bridge works for both player attack and player defense.
- [ ] No result can be applied twice to the same battle id.
- [ ] If battle loading fails, campaign state remains recoverable.

## Milestone 5: First Campaign Arc

Goal: ship a complete short campaign from opening region to final battle.

### Campaign Content

- [ ] Build 8-12 final or near-final prototype regions.
- [ ] Define region names, terrain tags, ownership, and income.
- [ ] Define at least 3 battle map variants or scene setups.
- [ ] Define at least 2 key regions with unique objectives or modifiers.
- [ ] Define one final objective region.
- [ ] Define starting player region and starting enemy region.
- [ ] Define campaign pacing for early, mid, and final stages.

### Factions And Progression

- [ ] Player faction has complete v1 roster.
- [ ] Enemy faction has complete v1 roster or AI-only equivalents.
- [ ] Add 4-6 campaign techs.
- [ ] Each tech has at least one visible battle or campaign effect.
- [ ] Enemy escalation changes over time or territory progress.
- [ ] Player has at least one meaningful strategic choice each turn.

### Story And Events

- [ ] Write opening campaign text.
- [ ] Write region capture/loss event text.
- [ ] Write enemy escalation alerts.
- [ ] Write final objective reveal.
- [ ] Write campaign victory text.
- [ ] Write campaign defeat text.
- [ ] Keep story text short enough not to block strategy flow.

### Save, Load, And Stability

- [ ] Campaign can save manually or automatically at turn boundaries.
- [ ] Campaign can load and preserve region ownership.
- [ ] Campaign can load and preserve armies.
- [ ] Campaign can load and preserve resources and research.
- [ ] Campaign can load before and after manual battle.
- [ ] Failed or abandoned battle sessions do not corrupt the campaign save.

### Polish Pass

- [ ] Campaign UI is readable at target resolution.
- [ ] RTS HUD remains readable during battles launched from campaign.
- [ ] Important alerts have audio or strong visual feedback.
- [ ] Placeholder art is clearly marked or replaced.
- [ ] Debug-only UI is hidden from normal play.
- [ ] Default difficulty is beatable by a first-time tester.
- [ ] Known rough edges are documented.

### Acceptance Criteria

- [ ] Player can complete a short campaign from first region to final battle.
- [ ] Campaign can be won and lost.
- [ ] Manual RTS battles and campaign turns remain connected through the whole arc.
- [ ] Save/load supports continuing the campaign across sessions.
- [ ] The campaign demonstrates the core promise: strategic choices affect real battles, and battles reshape the strategic map.

## Cross-Milestone Definition Of Done

- [ ] Feature works from a clean launch, not only after editor setup.
- [ ] Required assets are project-relative where possible.
- [ ] UI communicates unavailable, invalid, pending, active, completed, victory, and defeat states.
- [ ] Logs are useful for debugging but not required to understand normal gameplay.
- [ ] Systems fail gracefully when expected entities or assets are missing.
- [ ] New data ids are stable enough for save files and campaign bridge references.
- [ ] No design-critical behavior depends on copyrighted names, lore, factions, or assets from reference games.
