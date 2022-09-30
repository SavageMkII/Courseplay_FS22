--[[
This file is part of Courseplay (https://github.com/Courseplay/courseplay)
Copyright (C) 2022 Peter Vaiko

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

--- Drive strategy for bunker silos.
---@class AIDriveStrategyBunkerSilo : AIDriveStrategyCourse
AIDriveStrategyBunkerSilo = {}
local AIDriveStrategyBunkerSilo_mt = Class(AIDriveStrategyBunkerSilo, AIDriveStrategyCourse)

AIDriveStrategyBunkerSilo.myStates = {
    DRIVING_TO_SILO = {},
    DRIVING_TO_PARK_POSITION = {},
    DRIVING_INTO_SILO = {},
	DRIVING_OUT_OF_SILO = {},
    DRIVING_TEMPORARY_OUT_OF_SILO = {}
}

AIDriveStrategyBunkerSilo.siloEndProximitySensorRange = 4
AIDriveStrategyBunkerSilo.isStuckMs = 1000 *15
AIDriveStrategyBunkerSilo.isStuckBackOffset = 5

function AIDriveStrategyBunkerSilo.new(customMt)
    if customMt == nil then
        customMt = AIDriveStrategyBunkerSilo_mt
    end
    ---@type AIDriveStrategyBunkerSilo
    local self = AIDriveStrategyCourse.new(customMt)
    AIDriveStrategyCourse.initStates(self, AIDriveStrategyBunkerSilo.myStates)
    self.state = self.states.DRIVING_TO_SILO

    -- course offsets dynamically set by the AI and added to all tool and other offsets
    self.aiOffsetX, self.aiOffsetZ = 0, 0
    self.debugChannel = CpDebug.DBG_SILO
    ---@type ImplementController[]
    self.controllers = {}
	self.silo = nil
    self.siloController = nil
    self.drivingForwardsIntoSilo = true

    

    self.isStuckTimer = Timer.new(self.isStuckMs)
    return self
end

function AIDriveStrategyBunkerSilo:delete()
    self.silo:resetTarget(self.vehicle)
    self.isStuckTimer:delete()
    if self.pathfinderNode then
       self.pathfinderNode:destroy()
    end
    if self.parkNode then 
        self.parkNode:destroy()
    end
    AIDriveStrategyBunkerSilo:superClass().delete(self)
end

function AIDriveStrategyBunkerSilo:startWithoutCourse(jobParameters)
    self:info('Starting bunker silo mode.')


    if self.leveler then 
        if AIUtil.isObjectAttachedOnTheBack(self.vehicle, self.leveler) then 
            self.drivingForwardsIntoSilo = false
        end
    else 
        self.drivingForwardsIntoSilo = jobParameters.drivingForwardsIntoSilo:getValue()
    end

    --- Setup the silo controller, that handles the driving conditions and coordinations.
	self.siloController = self.silo:setupTarget(self.vehicle, self, self.drivingForwardsIntoSilo)

    if self.silo:isVehicleInSilo(self.vehicle) then 
        self:startDrivingIntoSilo()
    else 
        --- TODO: Figure out how to enable reverse driven goal for pathfinder?
        local course, firstWpIx = self:getDriveIntoSiloCourse()
        self:startCourseWithPathfinding( course, firstWpIx, self:isDriveDirectionReverse())
    end
end

function AIDriveStrategyBunkerSilo:getGeneratedCourse()
    return nil    
end

-----------------------------------------------------------------------------------------------------------------------
--- Implement handling
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyBunkerSilo:initializeImplementControllers(vehicle)
    self.leveler = self:addImplementController(vehicle, LevelerController, Leveler, {})
    self:addImplementController(vehicle, BunkerSiloCompacterController, BunkerSiloCompacter, {})
end

-----------------------------------------------------------------------------------------------------------------------
--- Static parameters (won't change while driving)
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyBunkerSilo:setAllStaticParameters()
    AIDriveStrategyCourse.setAllStaticParameters(self)
    self:setFrontAndBackMarkers()
    self.proximityController:registerIgnoreObjectCallback(self, self.ignoreProximityObject)

    self.siloEndNode = self:isDriveDirectionReverse() and Markers.getBackMarkerNode(self.vehicle) or Markers.getFrontMarkerNode(self.vehicle)

    --- Proximity sensor to detect the silo end wall.
    self.siloEndProximitySensor = ProximitySensorPack("siloEnd", self.vehicle, self.siloEndNode, self.siloEndProximitySensorRange, 1,
                                 {0}, {}, false)

    self.isStuckTimer:setFinishCallback(function ()
            self:debug("is stuck, trying to drive out of the silo.")
            if self:isTemporaryOutOfSiloDrivingAllowed() and not self.frozen then 
                self:startDrivingTemporaryOutOfSilo()
            end
        end)

end

function AIDriveStrategyBunkerSilo:setSilo(silo)
	self.silo = silo	
end

function AIDriveStrategyBunkerSilo:setParkPosition(parkPosition)
    self.parkPosition = parkPosition    
    if self.parkPosition.x ~= nil and self.parkPosition.z ~= nil and self.parkPosition.angle ~= nil then
        self.parkNode = CpUtil.createNode("parkNode", self.parkPosition.x, self.parkPosition.z, self.parkPosition.angle)
    end
end

-----------------------------------------------------------------------------------------------------------------------
--- Event listeners
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyBunkerSilo:onWaypointPassed(ix, course)
    if course:isLastWaypointIx(ix) then
        if self.state == self.states.DRIVING_INTO_SILO then 
            self:startDrivingOutOfSilo()
        elseif self.state == self.states.DRIVING_OUT_OF_SILO then 
            self:startDrivingIntoSilo()
        elseif self.state == self.states.DRIVING_TO_SILO then
            local course = self:getRememberedCourseAndIx()
            self:startDrivingIntoSilo(course)
        elseif self.state == self.states.DRIVING_TEMPORARY_OUT_OF_SILO then
            self:startDrivingIntoSilo(self.lastCourse)
            self.lastCourse = nil
        end
    end
end

function AIDriveStrategyBunkerSilo:getDriveData(dt, vX, vY, vZ)
    local moveForwards = not self.ppc:isReversing()
    local gx, gz, maxSpeed

    if not moveForwards then
        gx, gz, maxSpeed = self:getReverseDriveData()
       -- self:setMaxSpeed(maxSpeed)
    else
        gx, _, gz = self.ppc:getGoalPointPosition()
    end

    local moveForwards = not self.ppc:isReversing()
    self:updateLowFrequencyImplementControllers()
    self:drive()
    AIDriveStrategyFieldWorkCourse.setAITarget(self)
    self:setMaxSpeed(self.siloController:getMaxSpeed())
	self:setMaxSpeed(self.settings.bunkerSiloSpeed:getValue())
    self:checkProximitySensors(moveForwards)

    if self:isTemporaryOutOfSiloDrivingAllowed() then
        self.isStuckTimer:startIfNotRunning()
    end

    if self.silo:hasNearbyUnloader() then 
        self:setInfoText(InfoTextManager.WAITING_FOR_UNLOADER)
    else
        self:clearInfoText(InfoTextManager.WAITING_FOR_UNLOADER)
    end
    
    if self.state == self.states.WAITING_FOR_PATHFINDER then
        self:setMaxSpeed(0)
    end

    return gx, gz, moveForwards, self.maxSpeed, 100
end

function AIDriveStrategyBunkerSilo:isTemporaryOutOfSiloDrivingAllowed()
    return self.state == self.states.DRIVING_INTO_SILO and 
            AIUtil.isStopped(self.vehicle) 
            and not self.silo:hasNearbyUnloader() 
            and not self.proximityController:isStopped()
end

function AIDriveStrategyBunkerSilo:checkProximitySensors(moveForwards)
    AIDriveStrategyBunkerSilo:superClass().checkProximitySensors(self, moveForwards)
    if self.state == self.states.DRIVING_INTO_SILO then
        local _, _, closestObject = self.siloEndProximitySensor:getClosestObjectDistanceAndRootVehicle()
        if self.silo:isTheSameSilo(closestObject) then
            self:debug("End wall detected.")
            self:startDrivingOutOfSilo()
        end
    end
end

function AIDriveStrategyBunkerSilo:update(dt)
    AIDriveStrategyBunkerSilo:superClass().update(self, dt)
    self:updateImplementControllers(dt)

    if CpDebug:isChannelActive(self.debugChannel, self.vehicle) then 
        if self.course then
            -- TODO_22 check user setting
            if self.course:isTemporary() then
                self.course:draw()
            elseif self.ppc:getCourse():isTemporary() then
                self.ppc:getCourse():draw()
            end
        end
        DebugUtil.drawDebugNode(self.siloEndNode, "SiloEndNode", false, 1)

        local frontMarkerNode, backMarkerNode = Markers.getMarkerNodes(self.vehicle)
        DebugUtil.drawDebugNode(frontMarkerNode, "FrontMarker", false, 1)
        DebugUtil.drawDebugNode(backMarkerNode, "BackMarker", false, 1)
        if self.parkNode then 
            DebugUtil.drawDebugNode(self.parkNode, "ParkNode", true, 3)
        end
    end
end

-----------------------------------------------------------------------------------------------------------------------
--- Bunker silo interactions
-----------------------------------------------------------------------------------------------------------------------

function AIDriveStrategyBunkerSilo:drive()
    if self.state == self.states.DRIVING_INTO_SILO then 

        local marker = self:isDriveDirectionReverse() and Markers.getBackMarkerNode(self.vehicle) or Markers.getFrontMarkerNode(self.vehicle)

        if self.siloController:isEndReached(marker, self:getEndOffset(), self:isDriveDirectionReverse()) then 
            self:debug("End is reached.")
            self:startDrivingOutOfSilo()
        end
    end
end

--- Is the drive direction to drive into the silo reverse?
function AIDriveStrategyBunkerSilo:isDriveDirectionReverse()
    return not self.drivingForwardsIntoSilo
end

function AIDriveStrategyBunkerSilo:getStartOffset()
    local frontMarkerNode, backMarkerNode = Markers.getMarkerNodes(self.vehicle)
    local x, _, z = getTranslation(frontMarkerNode)
    local dx, _, dz =  getTranslation(backMarkerNode)
    return MathUtil.vector2Length(x - dx, z - dz)
end

function AIDriveStrategyBunkerSilo:getEndOffset()
    return 0
end

--- Gets the work width.
function AIDriveStrategyBunkerSilo:getWorkWidth()
    return self.settings.bunkerSiloWorkWidth:getValue()
end

--- Starts driving into the silo.
function AIDriveStrategyBunkerSilo:startDrivingIntoSilo(oldCourse)
    local firstWpIx
    if not oldCourse then 
        self.course, firstWpIx = self:getDriveIntoSiloCourse()
    else 
        self.course = oldCourse
        firstWpIx = self:getNearestWaypoints(oldCourse, self:isDriveDirectionReverse())
    end
    self:startCourse(self.course, firstWpIx)
    self.state = self.states.DRIVING_INTO_SILO
    self:lowerImplements()
    self:debug("Started driving into the silo.")
end

--- Start driving out of silo.
function AIDriveStrategyBunkerSilo:startDrivingOutOfSilo()
    local firstWpIx
    self.course, firstWpIx = self:getDriveOutOfSiloCourse(self.course)
    self:startCourse(self.course, firstWpIx)
    self.state = self.states.DRIVING_OUT_OF_SILO
    self:raiseImplements()
    self:debug("Started driving out of the silo.")
end

function AIDriveStrategyBunkerSilo:startDrivingTemporaryOutOfSilo()
    self.lastCourse = self.course
    local driveDirection = self:isDriveDirectionReverse()
    if driveDirection then
		self.course = Course.createStraightForwardCourse(self.vehicle, self.isStuckBackOffset, 0)
	else 
        self.course = Course.createStraightReverseCourse(self.vehicle, self.isStuckBackOffset, 0)
	end
    self:startCourse(self.course, 1)
    self.state = self.states.DRIVING_TEMPORARY_OUT_OF_SILO
    self:raiseImplements()
    self:debug("Started driving temporary out of the silo.")
end

--- Create a straight course into the silo.
---@return Course generated course 
---@return number first waypoint of the course relative to the vehicle position.
function AIDriveStrategyBunkerSilo:getDriveIntoSiloCourse()
	local driveDirection = self:isDriveDirectionReverse()
	
    local startPos, endPos = self.siloController:getTarget(self:getWorkWidth())
    local x, z = unpack(startPos)
    local dx, dz = unpack(endPos)

    local course = Course.createFromTwoWorldPositions(self.vehicle, x, z, dx, dz, 0, 
                                                -self:getStartOffset() + 3 , 0, 3, driveDirection)

	local firstWpIx = self:getNearestWaypoints(course, driveDirection)
	return course, firstWpIx
end

--- Create a straight course out of the silo.
---@param driveInCourse Course drive into the course, which will be inverted.
---@return Course generated course 
---@return number first waypoint of the course relative to the vehicle position.
function AIDriveStrategyBunkerSilo:getDriveOutOfSiloCourse(driveInCourse)
	local driveDirection = self:isDriveDirectionReverse()
    local x, _, z, dx, dz
    if driveInCourse then
        x, _, z = driveInCourse:getWaypointPosition(driveInCourse:getNumberOfWaypoints())
        dx, _, dz = driveInCourse:getWaypointPosition(1)
    else 
        local startPos, endPos = self.siloController:getTarget(self:getWorkWidth())
        x, z = unpack(endPos)
        dx, dz = unpack(startPos)
    end

	local course = Course.createFromTwoWorldPositions(self.vehicle, x, z, dx, dz, 0, -self:getEndOffset(), 
    self:getStartOffset(), 3, not driveDirection)
	local firstWpIx = self:getNearestWaypoints(course, not driveDirection)
	return course, firstWpIx
end

function AIDriveStrategyBunkerSilo:getNearestWaypoints(course, reverse)
    if reverse then 
        local ix = course:getNextRevWaypointIxFromVehiclePosition(1, self.vehicle:getAIDirectionNode(), 10)
        return ix
    end
    local firstWpIx = course:getNearestWaypoints(self.vehicle:getAIDirectionNode())
    return firstWpIx
end

--- Stops the driver, as the silo was deleted.
function AIDriveStrategyBunkerSilo:stopSiloWasDeleted()
    self.vehicle:stopCurrentAIJob(AIMessageErrorUnknown.new())
end

-----------------------------------------------------------------------------------------------------------------------
--- Leveler interactions
-----------------------------------------------------------------------------------------------------------------------

function AIDriveStrategyBunkerSilo:isLevelerLoweringAllowed()
    return self.state == self.states.DRIVING_INTO_SILO
end

--- Ignores the bunker silo for the proximity sensors.
function AIDriveStrategyBunkerSilo:ignoreProximityObject(object, vehicle)
    if self.silo:isTheSameSilo(object) then
        return true 
    end
    --- This ignores the terrain.
    if object == nil then
        return true
    end
end

------------------------------------------------------------------------------------------------------------------------
--- Pathfinding
---------------------------------------------------------------------------------------------------------------------------
---@param course Course
---@param ix number
function AIDriveStrategyBunkerSilo:startCourseWithPathfinding(course, ix, isReverse)
    if not self.pathfinder or not self.pathfinder:isActive() then
        -- set a course so the PPC is able to do its updates.
        self.course = course
        self.ppc:setCourse(self.course)
        self.ppc:initialize(ix)
        self:rememberCourse(course, ix)
        self:setFrontAndBackMarkers()
        local x, _, z = course:getWaypointPosition(ix)
        self:debug('offsetx %.1f, x %.1f, z %.1f', course.offsetX, x, z)
        self.state = self.states.WAITING_FOR_PATHFINDER    
        self.pathfindingStartedAt = g_currentMission.time
        local done, path
        local _, steeringLength = AIUtil.getSteeringParameters(self.vehicle)
        -- always drive a behind the target waypoint so there's room to straighten out towed implements
        -- a bit before start working
        self:debug('Pathfinding to waypoint %d, with zOffset min(%.1f, %.1f)', ix, -self.frontMarkerDistance, -steeringLength)

        if not self.pathfinderNode then 
            self.pathfinderNode = WaypointNode('pathfinderNode')
        end
        self.pathfinderNode:setToWaypoint(course, 1)
        if isReverse then
            --- Enables reverse path finding.
            local _, yRot, _ = getRotation(self.pathfinderNode.node)
            setRotation(self.pathfinderNode.node, 0, yRot + math.pi, 0)
        end

        self.pathfinder, done, path = PathfinderUtil.startPathfindingFromVehicleToNode(self.vehicle, self.pathfinderNode.node,
            0, 0, true)

      --  self.pathfinder, done, path = PathfinderUtil.startPathfindingFromVehicleToWaypoint(
      --      self.vehicle, course, ix, 0, 0,
       --     true, nil)
        if done then
            return self:onPathfindingDoneToCourseStart(path)
        else
            self:setPathfindingDoneCallback(self, self.onPathfindingDoneToCourseStart)
            return true
        end
    else
        self:info('Pathfinder already active!')
        self.state = self.states.DRIVING_TO_SILO
        return false
    end
end

function AIDriveStrategyBunkerSilo:onPathfindingDoneToCourseStart(path)
    local course, ix = self:getRememberedCourseAndIx()
    if path and #path > 2 then
        self:debug('Pathfinding to start fieldwork finished with %d waypoints (%d ms)',
                #path, g_currentMission.time - (self.pathfindingStartedAt or 0))
        course = Course(self.vehicle, CourseGenerator.pointsToXzInPlace(path), true)
        ix = 1
        self.state = self.states.DRIVING_TO_SILO
        self:startCourse(course, ix)
    else
        self:debug('Pathfinding to silo failed, directly start.')
        self:startDrivingIntoSilo(course)
    end
end
