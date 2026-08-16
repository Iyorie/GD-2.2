local Players=game:GetService("Players")
local HttpService=game:GetService("HttpService")
local player=Players.LocalPlayer
local MatchClient=require(player.PlayerGui.Client.MatchClient)

local API_URL="https://chess-api.com/v1"
local DEPTH=12
local highlights={}
local updateId=0
local processing=false
local states={}
local FILES={"a","b","c","d","e","f","g","h"}
local PIECES={Pawn="p",Knight="n",Bishop="b",Rook="r",Queen="q",King="k"}

local function clearHighlights()
	for _,v in pairs(highlights) do
		if v then
			v:Destroy()
		end
	end
	table.clear(highlights)
end

local function algebraicToGrid(square)
	if type(square)~="string" or #square~=2 then return end

	local file=square:sub(1,1)
	local rank=tonumber(square:sub(2,2))

	if not rank or rank<1 or rank>8 then return end

	for i,v in ipairs(FILES) do
		if v==file then
			return 9-i,rank
		end
	end
end

local function gridToAlgebraic(x,y)
	if not x or not y or x<1 or x>8 or y<1 or y>8 then return end
	return FILES[9-x]..y
end

local function findTile(board,x,y)
	return board.tiles[x] and board.tiles[x][y]
end

local function highlightTile(tile,color)
	if not tile then return end

	local v=Instance.new("SelectionBox")
	v.SurfaceColor3=color
	v.Color3=color
	v.SurfaceTransparency=0.25
	v.Transparency=0
	v.LineThickness=0.1
	v.Adornee=tile
	v.Parent=tile

	table.insert(highlights,v)
end

local function getTeam(board)
	if not board or not board.players then return end
	if board.players[true]==player then return true end
	if board.players[false]==player then return false end
end

local function getState(board)
	local key=tostring(board)

	if not states[key] then
		states[key]={
			K=false,
			Q=false,
			k=false,
			q=false,
			ep="-",
			half=0,
			full=1,
			snapshot=nil,
			ready=false
		}
	end

	return states[key]
end

local function getSnapshot(board)
	if not board or not board.boardExists then return end

	local snap={}
	local wk,bk=0,0
	local count=0

	for y=1,8 do
		for x=1,8 do
			local piece=board:getPiece({x,y})

			if piece then
				local key=x..":"..y

				snap[key]={
					name=piece.Name,
					team=piece.team,
					x=x,
					y=y
				}

				count+=1

				if piece.Name=="King" then
					if piece.team then
						wk+=1
					else
						bk+=1
					end
				end
			end
		end
	end

	return snap,wk,bk,count
end

local function getPieceAt(snap,x,y)
	return snap and snap[x..":"..y]
end

local function samePiece(a,b)
	return a and b and a.name==b.name and a.team==b.team
end

local function getChanges(before,after)
	local removed={}
	local added={}

	for key,piece in pairs(before) do
		local current=after[key]

		if not current then
			removed[#removed+1]=piece
		elseif not samePiece(piece,current) then
			removed[#removed+1]=piece
			added[#added+1]=current
		end
	end

	for key,piece in pairs(after) do
		if not before[key] then
			added[#added+1]=piece
		end
	end

	return removed,added
end

local function findMovedPiece(before,after,team)
	local candidates={}

	for _,old in pairs(before) do
		if old.team==team then
			local current=getPieceAt(after,old.x,old.y)

			if not current or not samePiece(old,current) then
				candidates[#candidates+1]=old
			end
		end
	end

	for _,old in ipairs(candidates) do
		for _,new in pairs(after) do
			if new.team==team and old.name==new.name then
				if old.x~=new.x or old.y~=new.y then
					return old,new
				end
			end
		end
	end
end

local function hasPiece(snap,x,y,name,team)
	local piece=getPieceAt(snap,x,y)

	return piece
		and piece.name==name
		and piece.team==team
end

local function refreshCastling(state,snap)
	state.K=hasPiece(snap,8,1,"Rook",true) and hasPiece(snap,5,1,"King",true) or false
	state.Q=hasPiece(snap,1,1,"Rook",true) and hasPiece(snap,5,1,"King",true) or false
	state.k=hasPiece(snap,8,8,"Rook",false) and hasPiece(snap,5,8,"King",false) or false
	state.q=hasPiece(snap,1,8,"Rook",false) and hasPiece(snap,5,8,"King",false) or false
end

local function updateCastling(state,before,after)
	if not before or not after then return end

	if state.K and not hasPiece(after,8,1,"Rook",true) then
		state.K=false
	end

	if state.Q and not hasPiece(after,1,1,"Rook",true) then
		state.Q=false
	end

	if state.k and not hasPiece(after,8,8,"Rook",false) then
		state.k=false
	end

	if state.q and not hasPiece(after,1,8,"Rook",false) then
		state.q=false
	end

	local wkBefore=hasPiece(before,5,1,"King",true)
	local wkAfter=hasPiece(after,5,1,"King",true)

	local bkBefore=hasPiece(before,5,8,"King",false)
	local bkAfter=hasPiece(after,5,8,"King",false)

	if wkBefore and not wkAfter then
		state.K=false
		state.Q=false
	end

	if bkBefore and not bkAfter then
		state.k=false
		state.q=false
	end
end

local function updateMoveState(board,before,after)
	local state=getState(board)

	if not before or not after then
		state.snapshot=after
		return
	end

	local team=board.activeTeam
	local old,new=findMovedPiece(before,after,team)
	local removed,added=getChanges(before,after)

	updateCastling(state,before,after)

	state.ep="-"

	if not old or not new then
		state.snapshot=after
		return
	end

	local capture=#removed>#1

	if old.name=="Pawn" then
		state.half=0

		if math.abs(new.y-old.y)==2 then
			state.ep=gridToAlgebraic(old.x,(old.y+new.y)/2)
		end
	elseif capture then
		state.half=0
	else
		state.half+=1
	end

	if old.team==false then
		state.full+=1
	end

	state.snapshot=after
end

local function initializeState(board)
	if not board or not board.boardExists then return end

	local state=getState(board)
	local snap,wk,bk,count=getSnapshot(board)

	if not snap or wk~=1 or bk~=1 then
		return
	end

	if state.ready then
		return
	end

	state.snapshot=snap
	state.full=math.max(1,tonumber(board.round) and math.ceil(board.round/2) or 1)
	state.half=0
	state.ep="-"

	refreshCastling(state,snap)

	state.ready=true
end

local function getCastling(state)
	local v=""

	if state.K then v="K" end
	if state.Q then v..="Q" end
	if state.k then v..="k" end
	if state.q then v..="q" end

	return v=="" and "-" or v
end

local function buildFen(board)
	if not board or not board.boardExists then return end

	local snap,wk,bk=getSnapshot(board)

	if not snap or wk~=1 or bk~=1 then
		return
	end

	local state=getState(board)

	if not state.ready then
		initializeState(board)
		state=getState(board)
	end

	local rows={}

	for y=8,1,-1 do
		local row=""
		local empty=0

		for x=8,1,-1 do
			local piece=snap[x..":"..y]

			if piece then
				if empty>0 then
					row..=empty
					empty=0
				end

				local symbol=PIECES[piece.name]

				if not symbol then
					return
				end

				row..=(piece.team and string.upper(symbol) or string.lower(symbol))
			else
				empty+=1
			end
		end

		if empty>0 then
			row..=empty
		end

		rows[#rows+1]=row
	end

	local active=board.activeTeam and "w" or "b"
	local castling=getCastling(state)
	local ep=state.ep or "-"
	local half=math.max(0,tonumber(state.half) or 0)
	local full=math.max(1,tonumber(state.full) or 1)

	return table.concat(rows,"/").." "..active.." "..castling.." "..ep.." "..half.." "..full
end

local function validateFen(fen)
	if type(fen)~="string" then return false end

	local board,active,castling,ep,half,full=fen:match(
		"^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$"
	)

	if not board then return false end
	if active~="w" and active~="b" then return false end
	if castling~="-" and not castling:match("^[KQkq]+$") then return false end
	if ep~="-" and not ep:match("^[a-h][36]$") then return false end
	if not tonumber(half) or not tonumber(full) then return false end
	if tonumber(half)<0 or tonumber(full)<1 then return false end

	local rows=string.split(board,"/")

	if #rows~=8 then return false end

	local wk,bk=0,0

	for rank,row in ipairs(rows) do
		local count=0

		for i=1,#row do
			local c=row:sub(i, i)

			if c:match("%d") then
				local n=tonumber(c)

				if n<1 or n>8 then
					return false
				end

				count+=n
			elseif c:match("[prnbqkPRNBQK]") then
				count+=1

				if c=="K" then
					wk+=1
				elseif c=="k" then
					bk+=1
				end

				if (rank==1 or rank==8) and c:lower()=="p" then
					return false
				end
			else
				return false
			end
		end

		if count~=8 then
			return false
		end
	end

	if wk~=1 or bk~=1 then
		return false
	end

	if castling~="-" then
		if castling:find("K",1,true) and not board:find("K") then
			return false
		end
	end

	return true
end

local function getFreshFen(id)
	while id==updateId do
		local board=MatchClient.currentMatch

		if not board or not board.boardExists then
			task.wait(0.2)
			continue
		end

		local team=getTeam(board)

		if team==nil then
			task.wait(0.2)
			continue
		end

		if board.activeTeam~=team then
			return
		end

		local snap,wk,bk=getSnapshot(board)

		if snap and wk==1 and bk==1 then
			local state=getState(board)

			if not state.ready then
				initializeState(board)
			end

			local fen=buildFen(board)

			if fen and validateFen(fen) then
				return fen,board,snap
			end
		end

		task.wait(0.1)
	end
end

local function requestBestMove(fen)
	local ok,response=pcall(function()
		return request({
			Url=API_URL,
			Method="POST",
			Headers={
				["Content-Type"]="application/json"
			},
			Body=HttpService:JSONEncode({
				fen=fen,
				depth=DEPTH
			})
		})
	end)

	if not ok then
		warn("[BestMove] Request failed:",response)
		return
	end

	if not response or not response.Body then
		warn("[BestMove] Empty response")
		return
	end

	local decodeOk,data=pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)

	if not decodeOk or type(data)~="table" then
		warn("[BestMove] Invalid JSON:",response.Body)
		return
	end

	if data.type=="error" then
		warn("[BestMove] API error:",data.error,data.text)
		return
	end

	if type(data.from)~="string" or type(data.to)~="string" then
		warn("[BestMove] No move returned:",response.Body)
		return
	end

	return data
end

local function getBestMoveWithRetry(id)
	local rejected={}
	local attempts=0

	while id==updateId do
		local fen,board,snapshot=getFreshFen(id)

		if not fen or not board then
			return
		end

		if id~=updateId then
			return
		end

		if rejected[fen] then
			task.wait(0.25)
			continue
		end

		local data=requestBestMove(fen)

		if data then
			return data,board,snapshot
		end

		rejected[fen]=true
		attempts+=1

		local current=MatchClient.currentMatch

		if current and current==board and current.boardExists then
			local fresh=getSnapshot(current)

			if fresh then
				local state=getState(current)
				state.snapshot=fresh

				if attempts>=2 then
					state.ep="-"
				end
			end
		end

		task.wait(math.min(0.25+attempts*0.15,1))
	end
end

local function showBestMove(id)
	if processing then return end

	processing=true

	local data,board,snapshot=getBestMoveWithRetry(id)

	if id~=updateId then
		processing=false
		return
	end

	if not data or not board or not snapshot then
		processing=false
		return
	end

	local current=MatchClient.currentMatch

	if current~=board or not board.boardExists then
		processing=false
		return
	end

	local team=getTeam(board)

	if team==nil or board.activeTeam~=team then
		processing=false
		return
	end

	local currentSnapshot=getSnapshot(board)

	if not currentSnapshot then
		processing=false
		return
	end

	local fx,fy=algebraicToGrid(data.from)
	local tx,ty=algebraicToGrid(data.to)

	if not fx or not fy or not tx or not ty then
		warn("[BestMove] Invalid coordinates:",data.from,data.to)
		processing=false
		return
	end

	local fromPiece=snapshot[fx..":"..fy]

	if not fromPiece then
		processing=false
		return
	end

	local fromTile=findTile(board,fx,fy)
	local toTile=findTile(board,tx,ty)

	if not fromTile or not toTile then
		warn("[BestMove] Couldn't find tiles:",fx,fy,tx,ty)
		processing=false
		return
	end

	clearHighlights()

	local color=Color3.fromRGB(255,204,101)

	highlightTile(fromTile,color)
	highlightTile(toTile,color)

	print("[BestMove]",data.from.." -> "..data.to,data.san or "")

	processing=false
end

local function update()
	updateId+=1

	local id=updateId

	clearHighlights()

	task.spawn(function()
		task.wait()

		if id~=updateId then
			return
		end

		showBestMove(id)
	end)
end

local oldProcessRound=MatchClient.processRound

MatchClient.processRound=function(self,piece,to,info)
	local board=MatchClient.currentMatch
	local before
	local oldTeam

	if board and board.boardExists then
		initializeState(board)

		before=getSnapshot(board)
		oldTeam=board.activeTeam

		if getTeam(board)==oldTeam then
			clearHighlights()
			updateId+=1
		end
	end

	local result=oldProcessRound(self,piece,to,info)

	local newBoard=MatchClient.currentMatch

	if newBoard and newBoard.boardExists then
		local after=getSnapshot(newBoard)

		if newBoard==board and before and after then
			local state=getState(newBoard)

			if state.snapshot then
				updateMoveState(newBoard,before,after)
			else
				state.snapshot=after
			end
		elseif after then
			local state=getState(newBoard)
			state.snapshot=after
		end

		local team=getTeam(newBoard)

		if team~=nil and newBoard.activeTeam==team then
			update()
		end
	end

	return result
end

local connections=game.ReplicatedStorage:FindFirstChild("Connections")

if connections then
	local startGame=connections:FindFirstChild("StartGame")
	local endGame=connections:FindFirstChild("EndGame")

	if startGame then
		startGame.OnClientEvent:Connect(function()
			updateId+=1
			processing=false
			clearHighlights()
			table.clear(states)

			task.spawn(function()
				local deadline=os.clock()+5

				while os.clock()<deadline do
					local board=MatchClient.currentMatch

					if board and board.boardExists then
						local snap,wk,bk=getSnapshot(board)

						if snap and wk==1 and bk==1 then
							initializeState(board)
							update()
							return
						end
					end

					task.wait(0.1)
				end
			end)
		end)
	end

	if endGame then
		endGame.OnClientEvent:Connect(function()
			updateId+=1
			processing=false
			clearHighlights()
			table.clear(states)
		end)
	end
end

task.defer(function()
	local deadline=os.clock()+5

	while os.clock()<deadline do
		local board=MatchClient.currentMatch

		if board and board.boardExists then
			local snap,wk,bk=getSnapshot(board)

			if snap and wk==1 and bk==1 then
				initializeState(board)

				if getTeam(board)==board.activeTeam then
					update()
				end

				return
			end
		end

		task.wait(0.1)
	end
end)
