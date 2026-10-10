-- mbt-stc: started-task commands for MBT.
--
-- mbt run restart [-- STC]     (STC: the project name, upper case)
--
-- Restarts the project's server and compresses its development library on
-- the way. A deploy replaces members, and a replaced member's old space stays
-- dead until the library is compressed; a compress needs the library to
-- itself (DISP=OLD), which only happens while the server is down.
--
-- The order is left to MVS rather than to waiting here:
--   1. submit a compress job: it asks for the library DISP=OLD and waits
--      (IEF099I) while the running server holds it;
--   2. P <STC>: the server ends, the job gets the library and compresses;
--   3. S <STC>: the new server asks for its STEPLIB and waits until the
--      job is done.
-- The job is submitted before the stop because the stop may take mvsMF
-- with it (HTTPD); the console falls back to Hercules by itself.

local function jobcard(t)
  -- NOTIFY on a card of its own: mvsMF appends USER and PASSWORD to the
  -- last card, and without a NOTIFY it adds a placeholder (IKJ144I)
  local user = string.upper((t.mvsmf and t.mvsmf.user) or "")
  local cards = {
    "//MBTCOMP JOB (1),'MBT COMPRESS',CLASS=" .. t.jobclass .. ",",
    "//            MSGCLASS=" .. t.msgclass .. ",MSGLEVEL=(1,1)",
  }
  if user:match("^[A-Z@#$][A-Z0-9@#$]*$") and #user <= 7 then
    cards[2] = cards[2] .. ","
    cards[3] = "//            NOTIFY=" .. user
  end
  return cards
end

local function compress_jcl(t, lib, stc)
  local cards = jobcard(t)
  for _, c in ipairs({
    "//* Compress " .. lib .. " in place. Waits for the library",
    "//* until " .. stc .. " has stopped (mbt run restart).",
    "//COMP     EXEC PGM=IEBCOPY",
    "//SYSPRINT DD  SYSOUT=*",
    "//LIB      DD  DSN=" .. lib .. ",DISP=OLD",
    "//SYSUT3   DD  UNIT=SYSDA,SPACE=(TRK,(5,5))",
    "//SYSUT4   DD  UNIT=SYSDA,SPACE=(TRK,(5,5))",
    "//SYSIN    DD  *",
    "  COPY OUTDD=LIB,INDD=LIB",
    "/*",
    "//",
  }) do cards[#cards + 1] = c end
  return table.concat(cards, "\n") .. "\n"
end

-- active reports whether stc is in D A,L. A failing display (mvsMF going
-- down under it) counts as "still there": the caller asks again.
local function active(ctx, stc)
  local ok, lines = pcall(ctx.console, "D A,L")
  if not ok then return true end
  for _, l in ipairs(lines) do
    if l:match("^%s*" .. stc .. "%s") then return true end
  end
  return false
end

local function show(ctx, lines)
  for _, l in ipairs(lines) do ctx.log("  " .. l) end
end

mbt.command{
  name = "restart",
  description = "stop the server, compress its development library, start it again",
  run = function(ctx)
    local lib = ctx.project.deploy_target
    if not lib then
      error("restart: no deploy target -- the project builds no load modules, or this mbt is"
        .. " older than ctx.project.deploy_target (mbt 3.0.0-dev of 2026-10-10)")
    end
    local stc = string.upper(ctx.args[1] or ctx.project.name)
    if not stc:match("^[A-Z@#$][A-Z0-9@#$]*$") or #stc > 8 then
      error("restart: '" .. stc .. "' is not a started task name -- say: mbt run restart -- NAME")
    end
    local t = ctx.target()

    -- 1. the compress job, before anything stops
    local status, body = ctx.mvs.request{ method = "PUT", path = "/restjobs/jobs",
      body = compress_jcl(t, lib, stc), content_type = "text/plain" }
    if ctx.dry_run then
      ctx.log("(dry run) would stop " .. stc .. ", compress " .. lib .. ", start " .. stc)
      return
    end
    local jobid = body:match('"jobid"%s*:%s*"([^"]+)"')
    if status < 200 or status > 299 or not jobid then
      error("restart: the compress job was not submitted (HTTP " .. status .. "): " .. body)
    end
    ctx.log("compress job MBTCOMP " .. jobid .. " waits for " .. lib)

    -- 2. stop; if the stop does not go out, the job would wait for ever.
    -- A stop that went out without an answer is the normal case for a
    -- server that carries mvsMF: it answers its own stop with a 5xx while
    -- it quiesces, and mbt does not send it again elsewhere. Going on with
    -- the start is safe even if it did not arrive: the new server queues
    -- behind the compress job for the library, so two never run at once.
    local ok, err = pcall(function() show(ctx, (ctx.console("P " .. stc))) end)
    if not ok then
      if tostring(err):find("may have run", 1, true) then
        ctx.warn("P " .. stc .. " went out but its answer was lost (" .. tostring(err)
          .. ") -- waiting for it to end")
        -- the server is taking mvsMF down with it: an S sent now could reach
        -- the dying mvsMF and be lost. Wait until it has gone; by then mvsMF
        -- refuses the connection and the S goes to the next channel.
        local gone = false
        for _ = 1, 60 do
          if not active(ctx, stc) then gone = true break end
        end
        if not gone then
          error("restart: " .. stc .. " is still active after P -- not started again; check it,"
            .. " then S " .. stc .. " (the compress job MBTCOMP waits for the library)")
        end
      else
        pcall(ctx.console, "C MBTCOMP")
        error("restart: P " .. stc .. " failed, compress job cancelled: " .. tostring(err))
      end
    end

    -- 3. start: waits for the library until the compress is done
    local lines = ctx.console("S " .. stc)
    show(ctx, lines)

    -- 4. the fill after the compress; a server that carried mvsMF has just
    -- come back, so this may fail -- it is a report, not a step
    local ok2, code, list = pcall(ctx.mvs.request, { path = "/restfiles/ds?dslevel=" .. lib })
    local used = ok2 and code == 200 and list:match('"used"%s*:%s*"(%d+)"')
    local size = ok2 and code == 200 and list:match('"sizex"%s*:%s*"(%d+)"')
    if used then
      ctx.log(lib .. ": " .. used .. "% of " .. (size or "?") .. " tracks used after the compress")
    else
      ctx.log(lib .. ": fill not readable after the restart (mvsMF " .. tostring(code) .. ")")
    end
  end,
}
