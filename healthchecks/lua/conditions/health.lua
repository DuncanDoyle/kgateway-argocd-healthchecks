-- Health check for gateway.kgateway.dev kinds with standard metav1.Condition
-- status: Backend. (GatewayExtension belongs here once kgateway writes its
-- status; see kgateway#14792.)
-- One byte-identical copy is installed per kind; messages read obj.kind.
--
-- Status shape: status.conditions[] (standard metav1.Condition list).
-- Two condition types, both owned by kgateway
-- (api/v1alpha1/kgateway/backend_types.go):
--   Accepted            True/Accepted | False/Invalid
--   EndpointsDiscovered True/Discovered
--                     | False/{NoMatchingInstances,CredentialError,
--                              AuthorizationError,DiscoveryError,Degraded}
--
-- EndpointsDiscovered is a RUNTIME condition: a Backend can be Accepted=True
-- and still be failing endpoint discovery. We therefore aggregate over every
-- recognised condition rather than returning on the first True — returning
-- early on Accepted=True would report a broken backend as Healthy.
local hs = {}

-- Messages read obj.kind so this one script serves every kind of this status
-- shape byte-identically.

-- The union of condition types across every kind this script serves. A kind
-- whose types are missing here shows Progressing forever, with no error.
local RECOGNISED = { Accepted = true, EndpointsDiscovered = true }

-- Stale status describes the previous spec, so treat it as "not yet known"
-- rather than reporting a verdict about configuration that no longer exists.
local function isStale(obj, condition)
  if obj.metadata == nil or obj.metadata.generation == nil then
    return false
  end
  if condition.observedGeneration == nil then
    return false
  end
  return condition.observedGeneration ~= obj.metadata.generation
end

-- kgateway has been observed writing message: "" on policy conditions (see
-- the TrafficPolicy overridden_empty_message fixture). In Lua the
-- empty string is truthy, so `condition.message or fallback` would still pick
-- "" and the health badge would render blank. Skip empty messages explicitly.
local function messageOrFallback(condition, fallback)
  if condition.message ~= nil and condition.message ~= "" then
    return condition.message
  end
  return fallback
end

if obj.status ~= nil and obj.status.conditions ~= nil then
  local degradedMsg = nil
  local healthyMsg = nil
  local sawStale = false

  for _, condition in ipairs(obj.status.conditions) do
    if RECOGNISED[condition.type] then
      if isStale(obj, condition) then
        sawStale = true
      elseif condition.status == "False" then
        -- First failure wins the message; any failing condition is Degraded.
        if degradedMsg == nil then
          degradedMsg = messageOrFallback(condition, condition.type .. " is False")
        end
      elseif condition.status == "True" then
        if healthyMsg == nil then
          healthyMsg = messageOrFallback(condition, condition.type .. " is True")
        end
      end
    end
  end

  -- Precedence: Degraded > Progressing > Healthy.
  if degradedMsg ~= nil then
    hs.status = "Degraded"
    hs.message = degradedMsg
    return hs
  end
  if sawStale then
    hs.status = "Progressing"
    hs.message = "Waiting for " .. obj.kind .. " status"
    return hs
  end
  if healthyMsg ~= nil then
    hs.status = "Healthy"
    hs.message = healthyMsg
    return hs
  end
end

hs.status = "Progressing"
hs.message = "Waiting for " .. obj.kind .. " status"
return hs
