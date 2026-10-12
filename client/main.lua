-- Variables
local config = require 'config.client'
local sharedConfig = require 'config.shared'
local isLoggedIn = LocalPlayer.state.isLoggedIn
local meterIsOpen = false
local meterActive = false
local lastLocation = nil
local mouseActive = false
local garageZone, taxiParkingZone = nil, nil
local pickupLocation, dropOffLocation = nil, nil

-- used for polyzones
local isInsidePickupZone = false
local isInsideDropZone = false

local meterData = {
    fareAmount = 6,
    currentFare = 0,
    distanceTraveled = 0
}

local NpcData = {
    Active = false,
    CurrentNpc = nil,
    LastNpc = nil,
    CurrentDeliver = nil,
    LastDeliver = nil,
    Npc = nil,
    NpcBlip = nil,
    DeliveryBlip = nil,
    NpcTaken = false,
    NpcDelivered = false,
    CountDown = 180
}

local taxiPed = nil

local function resetNpcTask()
    NpcData = {
        Active = false,
        CurrentNpc = nil,
        LastNpc = nil,
        CurrentDeliver = nil,
        LastDeliver = nil,
        Npc = nil,
        NpcBlip = nil,
        DeliveryBlip = nil,
        NpcTaken = false,
        NpcDelivered = false
    }
end

local function resetMeter()
    meterData = {
        fareAmount = 6,
        currentFare = 0,
        distanceTraveled = 0
    }
end

local function whitelistedVehicle()
    local veh = GetEntityModel(cache.vehicle)
    local retval = false

    for i = 1, #config.allowedVehicles, 1 do
        if veh == joaat(config.allowedVehicles[i].model) then
            retval = true
        end
    end

    if veh == `dynasty` then
        retval = true
    end

    return retval
end

local function isDriver()
    return cache.seat == -1
end

local zone
local delieveryZone

-- Non-target (distance) mode: ox_lib sphere zones replace the per-frame
-- distance-polling threads. Each mission leg gets a marker zone (r=20, draws
-- the marker via the zone's per-tick `inside`) and a prompt zone (r=5, draws
-- the 3D prompt and handles the key press). Zones are destroyed and recreated
-- whenever the leg changes (pickup -> delivery), so they always track
-- NpcData.CurrentNpc / NpcData.CurrentDeliver.
local pickupMarkerZone, pickupPromptZone = nil, nil
local deliverMarkerZone, deliverPromptZone = nil, nil

local function removePickupZonesNT()
    if pickupMarkerZone then pickupMarkerZone:remove() pickupMarkerZone = nil end
    if pickupPromptZone then pickupPromptZone:remove() pickupPromptZone = nil end
end

local function removeDeliverZonesNT()
    if deliverMarkerZone then deliverMarkerZone:remove() deliverMarkerZone = nil end
    if deliverPromptZone then deliverPromptZone:remove() deliverPromptZone = nil end
end

local function npcDropoffKeyCheckNT()
    if not (NpcData.Active and NpcData.NpcTaken and NpcData.Npc) then return end
    if not isInsideDropZone then return end
    if IsControlJustPressed(0, 38) then
        TaskLeaveVehicle(NpcData.Npc, cache.vehicle, 0)
        SetEntityAsMissionEntity(NpcData.Npc, false, true)
        SetEntityAsNoLongerNeeded(NpcData.Npc)
        local targetCoords = sharedConfig.npcLocations.takeLocations[NpcData.LastNpc]
        TaskGoStraightToCoord(NpcData.Npc, targetCoords.x, targetCoords.y, targetCoords.z, 1.0, -1, 0.0, 0.0)
        SendNUIMessage({
            action = 'toggleMeter'
        })
        TriggerServerEvent('qb-taxi:server:NpcPay', meterData.currentFare)
        meterActive = false
        SendNUIMessage({
            action = 'resetMeter'
        })

        pickupLocation, dropOffLocation = nil, nil

        exports.aicore:Notify(locale('info.person_was_dropped_off'), 'success')
        if NpcData.DeliveryBlip then
            RemoveBlip(NpcData.DeliveryBlip)
        end
        local RemovePed = function(p)
            SetTimeout(60000, function()
                DeletePed(p)
            end)
        end
        RemovePed(NpcData.Npc)
        resetNpcTask()
        -- Defer removal: never mutate the zone list from inside its own tick callback
        SetTimeout(0, removeDeliverZonesNT)
    end
end

local function createDeliverZonesNT()
    removeDeliverZonesNT()
    local deliver = sharedConfig.npcLocations.deliverLocations[NpcData.CurrentDeliver]
    local dCoord = deliver.xyz
    deliverMarkerZone = lib.zones.sphere({
        coords = dCoord,
        radius = 20.0,
        debug = config.debugPoly,
        inside = function()
            DrawMarker(2, deliver.x, deliver.y, deliver.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.3, 0.3, 255, 255, 255, 255, false, false, 0, true, nil, nil, false)
        end
    })
    deliverPromptZone = lib.zones.sphere({
        coords = dCoord,
        radius = 5.0,
        debug = config.debugPoly,
        onEnter = function()
            isInsideDropZone = true
        end,
        onExit = function()
            isInsideDropZone = false
        end,
        inside = function()
            aicore.drawText3d({text = locale('info.drop_off_npc'), coords = dCoord})
            npcDropoffKeyCheckNT()
        end
    })
end

local function getDeliveryLocation()
    NpcData.CurrentDeliver = math.random(1, #sharedConfig.npcLocations.deliverLocations)
    if NpcData.LastDeliver then
        while NpcData.LastDeliver == NpcData.CurrentDeliver do
            NpcData.CurrentDeliver = math.random(1, #sharedConfig.npcLocations.deliverLocations)
        end
    end

    if NpcData.DeliveryBlip then
        RemoveBlip(NpcData.DeliveryBlip)
    end
    NpcData.DeliveryBlip = AddBlipForCoord(sharedConfig.npcLocations.deliverLocations[NpcData.CurrentDeliver].x, sharedConfig.npcLocations.deliverLocations[NpcData.CurrentDeliver].y, sharedConfig.npcLocations.deliverLocations[NpcData.CurrentDeliver].z)
    SetBlipColour(NpcData.DeliveryBlip, 3)
    SetBlipRoute(NpcData.DeliveryBlip, true)
    SetBlipRouteColour(NpcData.DeliveryBlip, 3)
    NpcData.LastDeliver = NpcData.CurrentDeliver
    if not config.useTarget then -- distance polling replaced by ox_lib sphere zones
        createDeliverZonesNT()
    end
end

local function npcPickupKeyCheckNT()
    if not (NpcData.Active and not NpcData.NpcTaken and NpcData.Npc) then return end
    if not isInsidePickupZone then return end
    if IsControlJustPressed(0, 38) then
        local maxSeats, freeSeat = GetVehicleMaxNumberOfPassengers(cache.vehicle), 0

        for i=maxSeats - 1, 0, -1 do
            if IsVehicleSeatFree(cache.vehicle, i) then
                freeSeat = i
                break
            end
        end

        pickupLocation = GetEntityCoords(cache.ped)

        meterIsOpen = true
        meterActive = true
        lastLocation = GetEntityCoords(cache.ped)
        SendNUIMessage({
            action = 'openMeter',
            toggle = true,
            meterData = config.meter
        })
        SendNUIMessage({
            action = 'toggleMeter'
        })
        ClearPedTasksImmediately(NpcData.Npc)
        FreezeEntityPosition(NpcData.Npc, false)
        TaskEnterVehicle(NpcData.Npc, cache.vehicle, -1, freeSeat, 1.0, 0)
        exports.aicore:Notify(locale('info.go_to_location'), 'inform')
        if NpcData.NpcBlip ~= nil then
            RemoveBlip(NpcData.NpcBlip)
        end
        getDeliveryLocation()
        dropOffLocation = config.pzLocations.dropLocations[NpcData.CurrentDeliver].coord.xyz
        NpcData.NpcTaken = true
        -- Defer removal: never mutate the zone list from inside its own tick callback
        SetTimeout(0, removePickupZonesNT)
    end
end

local function createPickupZonesNT()
    removePickupZonesNT()
    local take = sharedConfig.npcLocations.takeLocations[NpcData.CurrentNpc]
    local tCoord = take.xyz
    pickupMarkerZone = lib.zones.sphere({
        coords = tCoord,
        radius = 20.0,
        debug = config.debugPoly,
        inside = function()
            DrawMarker(2, take.x, take.y, take.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.3, 0.3, 255, 255, 255, 255, false, false, 0, true, nil, nil, false)
        end
    })
    pickupPromptZone = lib.zones.sphere({
        coords = tCoord,
        radius = 5.0,
        debug = config.debugPoly,
        onEnter = function()
            isInsidePickupZone = true
        end,
        onExit = function()
            isInsidePickupZone = false
        end,
        inside = function()
            aicore.drawText3d({text = locale('info.call_npc'), coords = tCoord})
            npcPickupKeyCheckNT()
        end
    })
end

-- useTarget mode: pickup key-press runs on the pickup box zone's per-tick
-- `inside` callback instead of a dedicated Wait(0) polling thread.
local function pickupInsideTarget()
    if NpcData.NpcTaken then return end
    if not whitelistedVehicle() then return end -- parity with onEnterCallZone gate
    if IsControlJustPressed(0, 38) then
        lib.hideTextUI()
        local veh = cache.vehicle
        local maxSeats, freeSeat = GetVehicleMaxNumberOfPassengers(veh), 0

        for i= maxSeats - 1, 0, -1 do
            if IsVehicleSeatFree(veh, i) then
                freeSeat = i
                break
            end
        end

        meterIsOpen = true
        meterActive = true

        lastLocation = GetEntityCoords(cache.ped)
        SendNUIMessage({
            action = 'openMeter',
            toggle = true,
            meterData = config.meter
        })
        SendNUIMessage({
            action = 'toggleMeter'
        })
        pickupLocation = GetEntityCoords(cache.ped)
        ClearPedTasksImmediately(NpcData.Npc)
        FreezeEntityPosition(NpcData.Npc, false)
        TaskEnterVehicle(NpcData.Npc, veh, -1, freeSeat, 1.0, 0)
        exports.aicore:Notify(locale('info.go_to_location'), 'inform')
        if NpcData.NpcBlip then
            RemoveBlip(NpcData.NpcBlip)
        end
        getDeliveryLocation()
        NpcData.NpcTaken = true
        createNpcDelieveryLocation()
        lib.hideTextUI()
        -- Defer removal: never mutate the zone list from inside its own tick callback
        SetTimeout(0, function()
            if zone then zone:remove() zone = nil end
        end)
    end
end

local function onEnterCallZone()
    if whitelistedVehicle() and not isInsidePickupZone and not NpcData.NpcTaken then
        isInsidePickupZone = true
        lib.showTextUI(locale('info.call_npc'), {position = 'left-center'})
    end
end

local function onExitCallZone()
    lib.hideTextUI()
    isInsidePickupZone = false
end

local function createNpcPickUpLocation()
    zone = lib.zones.box({
        coords = config.pzLocations.takeLocations[NpcData.CurrentNpc].coord,
        size = vec3(config.pzLocations.takeLocations[NpcData.CurrentNpc].height, config.pzLocations.takeLocations[NpcData.CurrentNpc].width, (config.pzLocations.takeLocations[NpcData.CurrentNpc].maxZ - config.pzLocations.takeLocations[NpcData.CurrentNpc].minZ)),
        rotation = config.pzLocations.takeLocations[NpcData.CurrentNpc].heading,
        debug = config.debugPoly,
        onEnter = onEnterCallZone,
        onExit = onExitCallZone,
        inside = pickupInsideTarget
    })
end



local function enumerateEntitiesWithinDistance(entities, isPlayerEntities, coords, maxDistance)
	local nearbyEntities = {}
	if coords then
		coords = vec3(coords.x, coords.y, coords.z)
	else
		coords = GetEntityCoords(cache.ped)
	end
	for k, entity in pairs(entities) do
		local distance = #(coords - GetEntityCoords(entity))
		if distance <= maxDistance then
			nearbyEntities[#nearbyEntities + 1] = isPlayerEntities and k or entity
		end
	end
	return nearbyEntities
end

local function getVehiclesInArea(coords, maxDistance) -- Vehicle inspection in designated area
	return enumerateEntitiesWithinDistance(GetGamePool('CVehicle'), false, coords, maxDistance)
end

local function isSpawnPointClear(coords, maxDistance)
	return #getVehiclesInArea(coords, maxDistance) == 0
end

local function getVehicleSpawnPoint()
	local clearSpots = {}
	for k, v in pairs(config.cabSpawns) do
		if isSpawnPointClear(vec3(v.x, v.y, v.z), 1.0) then
			clearSpots[#clearSpots + 1] = k
		end
	end
	if #clearSpots == 0 then return nil end
	return clearSpots[math.random(1, #clearSpots)]
end

local function calculateFareAmount()
    if meterIsOpen and meterActive then
        local startPos = lastLocation
        local newPos = GetEntityCoords(cache.ped)
        if startPos ~= newPos then
            local newDistance = #(startPos - newPos)
            lastLocation = newPos

            meterData['distanceTraveled'] += (newDistance / 1609)

            local fareAmount = 0

            if config.meter.useGpsPrice and pickupLocation and dropOffLocation then
                local totalRouteDistance = CalculateTravelDistanceBetweenPoints(pickupLocation.x, pickupLocation.y, pickupLocation.z, dropOffLocation.x, dropOffLocation.y, dropOffLocation.z) / 1609
                local progress = math.min(meterData['distanceTraveled'] / totalRouteDistance, 1.0)
                fareAmount = (totalRouteDistance * progress * config.meter.defaultPrice) + config.meter.startingPrice
            else
                fareAmount = (meterData['distanceTraveled'] * config.meter.defaultPrice) + config.meter.startingPrice
            end

            meterData['currentFare'] = math.floor(fareAmount)


            SendNUIMessage({
                action = 'updateMeter',
                meterData = meterData
            })
        end
    end
end

local function onEnterDropZone()
    if whitelistedVehicle() and not isInsideDropZone and NpcData.NpcTaken then
        isInsideDropZone = true
        lib.showTextUI(locale('info.drop_off_npc'), {position = 'left-center'})
    end
end

local function onExitDropZone()
    lib.hideTextUI()
    isInsideDropZone = false

end

-- useTarget mode: dropoff key-press runs on the delivery box zone's per-tick
-- `inside` callback instead of a dedicated Wait(0) polling thread. The teardown
-- (with its Wait(1000)) runs in a one-shot thread so the zone tick is never blocked.
local function dropoffInsideTarget()
    if not (NpcData.NpcTaken and NpcData.Npc) then return end
    if not whitelistedVehicle() then return end -- parity with onEnterDropZone gate
    if IsControlJustPressed(0, 38) then
        NpcData.NpcTaken = false -- single-shot; teardown below runs async
        CreateThread(function()
            lib.hideTextUI()
            local veh = cache.vehicle
            TaskLeaveVehicle(NpcData.Npc, veh, 0)
            Wait(1000)
            SetVehicleDoorShut(veh, 3, false)
            SetEntityAsMissionEntity(NpcData.Npc, false, true)
            SetEntityAsNoLongerNeeded(NpcData.Npc)
            local targetCoords = sharedConfig.npcLocations.takeLocations[NpcData.LastNpc]
            TaskGoStraightToCoord(NpcData.Npc, targetCoords.x, targetCoords.y, targetCoords.z, 1.0, -1, 0.0, 0.0)
            SendNUIMessage({
                action = 'toggleMeter'
            })
            TriggerServerEvent('qb-taxi:server:NpcPay', meterData.currentFare)
            meterActive = false
            SendNUIMessage({
                action = 'resetMeter'
            })
            exports.aicore:Notify(locale('info.person_was_dropped_off'), 'success')
            if NpcData.DeliveryBlip ~= nil then
                RemoveBlip(NpcData.DeliveryBlip)
            end
            local RemovePed = function(p)
                SetTimeout(60000, function()
                    DeletePed(p)
                end)
            end
            RemovePed(NpcData.Npc)
            resetNpcTask()
            if delieveryZone then delieveryZone:remove() delieveryZone = nil end
            lib.hideTextUI()
        end)
    end
end

function createNpcDelieveryLocation()
    delieveryZone = lib.zones.box({
        coords = config.pzLocations.dropLocations[NpcData.CurrentDeliver].coord,
        size = vec3(config.pzLocations.dropLocations[NpcData.CurrentDeliver].height, config.pzLocations.dropLocations[NpcData.CurrentDeliver].width, (config.pzLocations.dropLocations[NpcData.CurrentDeliver].maxZ - config.pzLocations.dropLocations[NpcData.CurrentDeliver].minZ)),
        rotation = config.pzLocations.dropLocations[NpcData.CurrentDeliver].heading,
        debug = config.debugPoly,
        onEnter = onEnterDropZone,
        onExit = onExitDropZone,
        inside = dropoffInsideTarget
    })
end

local function setLocationsBlip()
    if not config.useBlips then return end
    local taxiBlip = AddBlipForCoord(config.locations.main.coords.x, config.locations.main.coords.y, config.locations.main.coords.z)
    SetBlipSprite(taxiBlip, 198)
    SetBlipDisplay(taxiBlip, 4)
    SetBlipScale(taxiBlip, 0.6)
    SetBlipAsShortRange(taxiBlip, true)
    SetBlipColour(taxiBlip, 5)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(locale('info.blip_name'))
    EndTextCommandSetBlipName(taxiBlip)
end

local function taxiGarage()
    local registeredMenu = {
        id = 'garages_depotlist',
        title = locale('menu.taxi_menu_header'),
        options = {}
    }
    local options = {}
    for _, v in pairs(config.allowedVehicles) do

        options[#options + 1] = {
            title = v.label,
            event = 'qb-taxi:client:TakeVehicle',
            args = {model = v.model},
            icon = 'fa-solid fa-taxi'
        }
    end

    registeredMenu['options'] = options
    lib.registerContext(registeredMenu)
    lib.showContext('garages_depotlist')
end

local function setupGarageZone()
    if config.useTarget then
        lib.requestModel(`a_m_m_indian_01`)
        taxiPed = CreatePed(3, `a_m_m_indian_01`, 894.93, -179.12, 74.7 - 1.0, 237.09, false, true)
        SetModelAsNoLongerNeeded(`a_m_m_indian_01`)
        SetBlockingOfNonTemporaryEvents(taxiPed, true)
        FreezeEntityPosition(taxiPed, true)
        SetEntityInvincible(taxiPed, true)
        exports.ox_target:addLocalEntity(taxiPed, {
            {
                type = 'client',
                event = 'qb-taxijob:client:requestcab',
                icon = 'fa-solid fa-taxi',
                label = locale('info.request_taxi_target'),
                job = 'taxi',
            }
        })
    else
        local function onEnter()
            if not cache.vehicle then
                lib.showTextUI(locale('info.request_taxi'))
            end
        end

        local function onExit()
            lib.hideTextUI()
        end

        local function inside()
            if IsControlJustPressed(0, 38) then
                lib.hideTextUI()
                taxiGarage()
                return
            end
        end

        garageZone = lib.zones.box({
            coords = config.locations.garage.coords,
            size = vec3(1.6, 4.0, 2.8),
            rotation = 328.5,
            debug = config.debugPoly,
            inside = inside,
            onEnter = onEnter,
            onExit = onExit
        })
    end
end

local function destroyGarageZone()
    if not garageZone then return end

    garageZone:remove()
    garageZone = nil
end

function setupTaxiParkingZone()
        taxiParkingZone = lib.zones.box({
        coords = vec3(config.locations.main.coords.x, config.locations.main.coords.y, config.locations.main.coords.z),
        size = vec3(4.0, 4.0, 4.0),
        rotation = 55,
        debug = config.debugPoly,
        inside = function()
            if AICORE.PlayerData.job.name ~= 'taxi' then return end
            if IsControlJustPressed(0, 38) then
                if whitelistedVehicle() then
                    if meterIsOpen then
                        TriggerEvent('qb-taxi:client:toggleMeter')
                        meterActive = false
                    end
                    DeleteVehicle(cache.vehicle)
                    exports.aicore:Notify(locale('info.taxi_returned'), 'success')
                end
            end
        end,
        onEnter = function()
            lib.showTextUI(locale('info.vehicle_parking'))
        end,
        onExit = function()
            lib.hideTextUI()
        end
    })
end

local function destroyTaxiParkingZone()
    if not taxiParkingZone then return end

    taxiParkingZone:remove()
    taxiParkingZone = nil
end

RegisterNetEvent('qb-taxi:client:TakeVehicle', function(data)
    local SpawnPoint = getVehicleSpawnPoint()
    if SpawnPoint then
        local coords = config.cabSpawns[SpawnPoint]
        local CanSpawn = isSpawnPointClear(coords, 1.0)
        if CanSpawn then
            local netId = lib.callback.await('qb-taxi:server:spawnTaxi', false, data.model, coords)
            if not netId then
                exports.aicore:Notify(locale('info.no_spawn_point'), 'error')
                return
            end
            local veh = NetToVeh(netId)
            SetVehicleFuelLevel(veh, 100.0)
            SetVehicleEngineOn(veh, true, true, false)
        else
            exports.aicore:Notify(locale('info.no_spawn_point'), 'error')
        end
    else
        exports.aicore:Notify(locale('info.no_spawn_point'), 'error')
        return
    end
end)

-- Events
RegisterNetEvent('qb-taxi:client:DoTaxiNpc', function()
    if whitelistedVehicle() then
        if not NpcData.Active then
            NpcData.CurrentNpc = math.random(1, #sharedConfig.npcLocations.takeLocations)
            if NpcData.LastNpc ~= nil then
                while NpcData.LastNpc == NpcData.CurrentNpc do
                    NpcData.CurrentNpc = math.random(1, #sharedConfig.npcLocations.takeLocations)
                end
            end

            local Gender = math.random(1, #config.npcSkins)
            local PedSkin = math.random(1, #config.npcSkins[Gender])
            local model = GetHashKey(config.npcSkins[Gender][PedSkin])
            lib.requestModel(model)
            NpcData.Npc = CreatePed(3, model, sharedConfig.npcLocations.takeLocations[NpcData.CurrentNpc].x, sharedConfig.npcLocations.takeLocations[NpcData.CurrentNpc].y, sharedConfig.npcLocations.takeLocations[NpcData.CurrentNpc].z - 0.98, sharedConfig.npcLocations.takeLocations[NpcData.CurrentNpc].w, true, true)
            SetModelAsNoLongerNeeded(model)
            PlaceObjectOnGroundProperly(NpcData.Npc)
            FreezeEntityPosition(NpcData.Npc, true)
            if NpcData.NpcBlip ~= nil then
                RemoveBlip(NpcData.NpcBlip)
            end
            exports.aicore:Notify(locale('info.npc_on_gps'), 'success')

            -- added checks to disable distance checking if polyzone option is used
            if config.useTarget then
                createNpcPickUpLocation()
            end

            NpcData.NpcBlip = AddBlipForCoord(sharedConfig.npcLocations.takeLocations[NpcData.CurrentNpc].x, sharedConfig.npcLocations.takeLocations[NpcData.CurrentNpc].y, sharedConfig.npcLocations.takeLocations[NpcData.CurrentNpc].z)
            SetBlipColour(NpcData.NpcBlip, 3)
            SetBlipRoute(NpcData.NpcBlip, true)
            SetBlipRouteColour(NpcData.NpcBlip, 3)
            NpcData.LastNpc = NpcData.CurrentNpc
            NpcData.Active = true

            -- distance polling replaced by ox_lib sphere zones (see createPickupZonesNT)
            if not config.useTarget then
                createPickupZonesNT()
            end
        else
            exports.aicore:Notify(locale('error.already_mission'), 'error')
        end
    else
        exports.aicore:Notify(locale('error.not_in_taxi'), 'error')
    end
end)

RegisterNetEvent('qb-taxi:client:toggleMeter', function()
    if cache.vehicle then
        if whitelistedVehicle() then
            if not meterIsOpen and isDriver() then
                SendNUIMessage({
                    action = 'openMeter',
                    toggle = true,
                    meterData = config.meter
                })
                meterIsOpen = true
            else
                SendNUIMessage({
                    action = 'openMeter',
                    toggle = false
                })
                meterIsOpen = false
            end
        else
            exports.aicore:Notify(locale('error.missing_meter'), 'error')
        end
    else
        exports.aicore:Notify(locale('error.no_vehicle'), 'error')
    end
end)

RegisterNetEvent('qb-taxi:client:enableMeter', function()
    if meterIsOpen then
        SendNUIMessage({
            action = 'toggleMeter'
        })
    else
        exports.aicore:Notify(locale('error.not_active_meter'), 'error')
    end
end)

RegisterNetEvent('qb-taxi:client:toggleMuis', function()
    Wait(400)
    if meterIsOpen then
        if not mouseActive then
            SetNuiFocus(true, true)
            mouseActive = true
        end
    else
        exports.aicore:Notify(locale('error.no_meter_sight'), 'error')
    end
end)

RegisterNetEvent('qb-taxijob:client:requestcab', function()
    taxiGarage()
end)

-- NUI Callbacks
RegisterNUICallback('enableMeter', function(data, cb)
    meterActive = data.enabled
    if not meterActive then resetMeter() end
    lastLocation = GetEntityCoords(cache.ped)
    cb('ok')
end)

RegisterNUICallback('hideMouse', function(_, cb)
    SetNuiFocus(false, false)
    mouseActive = false
    cb('ok')
end)

-- Threads
CreateThread(function()
    while true do
        Wait(2000)
        calculateFareAmount()
    end
end)

CreateThread(function()
    while true do
        if not cache.vehicle then
            if meterIsOpen then
                SendNUIMessage({
                    action = 'openMeter',
                    toggle = false
                })
                meterIsOpen = false
            end
        end
        Wait(200)
    end
end)

local function init()
    if AICORE.PlayerData.job.name == 'taxi' then
        setupGarageZone()
        setupTaxiParkingZone()
        setLocationsBlip()
    end
end

RegisterNetEvent('QBCore:Client:OnJobUpdate', function()
    destroyGarageZone()
    destroyTaxiParkingZone()
    init()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    isLoggedIn = true
    init()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    isLoggedIn = false
end)

CreateThread(function()
    if not isLoggedIn then return end
    init()
end)