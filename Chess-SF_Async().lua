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
	if type(square)~="string" or #square<2 then return end

	local file=square:sub(1,1)
	local rank=tonumber(square:sub(2,2))

	if not rank then return end

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
	if board.players[true]==player then return true end
	if board.players[false]==player then return false end
end

local function getKey(board)
	return tostring(board)
end

local function getState(board)
	local key=getKey(board)

	if not states[key] then
		states[key]={
			K=true,
			Q=true,
			k=true,
			q=true,
			ep="-",
			half=0,
			full=1,
			snapshot=nil
		}
	end

	return states[key]
end

local function getSnapshot(board)
	if not board or not board.boardExists then return end

	local snap={}
	local kings={true=0,[false]=0}

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

				if piece.Name=="King" then
					kings[piece.team]+=1
				end
			end
		end
	end

	return snap,kings
end

local function getPieceAt(snap,x,y)
	return snap and snap[x..":"..y]
end

local function samePiece(a,b)
	return a and b and a.name==b.name and a.team==b.team
end

local function findMove(before,after)
	if not before or not after then return end

	local removed={}
	local added={}

	for key,piece in pairs(before) do
		if not after[key] then
			removed[#removed+1]=piece
		elseif not samePiece(piece,after[key]) then
			removed[#removed+1]=piece
		end
	end

	for key,piece in pairs(after) do
		if not before[key] then
			added[#added+1]=piece
		elseif not samePiece(before[key],piece) then
			added[#added+1]=piece
		end
	end

	if #removed==1 and #added==1 then
		return removed[1],added[1]
	end

	for _,old in ipairs(removed) do
		for _,new in ipairs(added) do
			if old.team==new.team and old.name==new.name then
				return old,new
			end
		end
	end
end

local function removeCastling(state,piece)
	if not piece then return end

	if piece.name=="King" then
		if piece.team then
			state.K=false
			state.Q=false
		else
			state.k=false
			state.q=false
		end
	elseif piece.name=="Rook" then
		if piece.team then
			if piece.x==8 and piece.y==1 then
				state.K=false
			elseif piece.x==1 and piece.y==1 then
				state.Q=false
			end
		else
			if piece.x==8 and piece.y==8 then
				state.k=false
			elseif piece.x==1 and piece.y==8 then
				state.q=false
			end
		end
	end
end

local function updateCastling(state,before,after)
	if not before or not after then return end

	for _,piece in pairs(before) do
		if piece.name=="King" or piece.name=="Rook" then
			local current=getPieceAt(after,piece.x,piece.y)

			if not current or not samePiece(piece,current) then
				removeCastling(state,piece)
			end
		end
	end

	local function checkRook(x,y,key,team)
		local piece=getPieceAt(after,x,y)

		if not piece or piece.name~="Rook" or piece.team~=team then
			state[key]=false
		end
	end

	if state.K then checkRook(8,1,"K",true) end
	if state.Q then checkRook(1,1,"Q",true) end
	if state.k then checkRook(8,8,"k",false) end
	if state.q then checkRook(1,8,"q",false) end
end

local function updateMoveState(board,before,after)
	local state=getState(board)

	if not before or not after then
		state.snapshot=after
		return
	end

	local old,new=findMove(before,after)

	if not old or not new then
		state.snapshot=after
		return
	end

	updateCastling(state,before,after)

	state.ep="-"

	local captured=false

	for key,piece in pairs(before) do
		local current=after[key]

		if piece and not current then
			if not (piece.x==old.x and piece.y==old.y) then
				captured=true
			end
		end
	end

	if old.name=="Pawn" then
		state.half=0

		if math.abs(new.y-old.y)==2 then
			local y=(old.y+new.y)/2
			state.ep=gridToAlgebraic(old.x,y)
		end
	elseif captured then
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

	if state.snapshot then return end

	local snapshot=getSnapshot(board)

	if not snapshot then return end

	state.snapshot=snapshot

	local round=tonumber(board.round)

	if round and round>0 then
		state.full=math.max(1,math.ceil(round/2))
	end
end

local function getCastling(state)
	local v=""

	if state.K then v="K" end
	if state.Q then v..="Q" end
	if state.k then v..="k" end
	if state.q then v..="q" end

	return v=="" and "-" or v
end

local function buildFreshFen(board)
	if not board or not board.boardExists then return end

	initializeState(board)

	local state=getState(board)
	local rows={}
	local wk,bk=0,0

	for y=8,1,-1 do
		local row=""
		local empty=0

		for x=8,1,-1 do
			local piece=board:getPiece({x,y})

			if piece then
				if empty>0 then
					row..=empty
					empty=0
				end

				local symbol=PIECES[piece.Name]

				if not symbol then return end

				if piece.Name=="King" then
					if piece.team then
						wk+=1
					else
						bk+=1
					end
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

	if wk~=1 or bk~=1 then return end

	local active=board.activeTeam and "w" or "b"
	local castling=getCastling(state)
	local half=math.max(0,tonumber(state.half) or 0)
	local full=math.max(1,tonumber(state.full) or 1)

	return table.concat(rows,"/").." "..active.." "..castling.." "..(state.ep or "-").." "..half.." "..full
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

	local rows=string.split(board,"/")

	if #rows~=8 then return false end

	local wk,bk=0,0

	for _,row in ipairs(rows) do
		local count=0

		for i=1,#row do
			local c=row:sub(i,i)

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
			else
				return false
			end
		end

		if count~=8 then
			return false
		end
	end

	return wk==1 and bk==1
end

local function getFreshFen(id)
	while id==updateId do
		local board=MatchClient.currentMatch

		if not board or not board.boardExists then
			task.wait(0.25)
			continue
		end

		local team=getTeam(board)

		if team==nil then
			task.wait(0.25)
			continue
		end

		if board.activeTeam~=team then
			return
		end

		local snapshot=getSnapshot(board)

		if snapshot then
			local state=getState(board)

			if not state.snapshot then
				state.snapshot=snapshot
			end
		end

		local fen=buildFreshFen(board)

		if fen and validateFen(fen) then
			return fen,board
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

	if not ok or not response then
		warn("[BestMove] Request failed:",response)
		return
	end

	if not response.Body then
		warn("[BestMove] Empty response")
		return
	end

	local decodeOk,data=pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)

	if not decodeOk or not data then
		warn("[BestMove] Invalid JSON:",response.Body)
		return
	end

	if data.type=="error" then
		warn("[BestMove] API error:",data.error,data.text)
		return
	end

	if not data.from or not data.to then
		warn("[BestMove] No move returned:",response.Body)
		return
	end

	return data
end

local function getBestMoveWithRetry(id)
	local rejected={}

	while id==updateId do
		local fen,board=getFreshFen(id)

		if not fen or not board then
			return
		end

		if id~=updateId then
			return
		end

		if rejected[fen] then
			task.wait(0.2)
			continue
		end

		local data=requestBestMove(fen)

		if data then
			return data,board
		end

		rejected[fen]=true

		local fresh=MatchClient.currentMatch

		if fresh and fresh.boardExists then
			local snapshot=getSnapshot(fresh)

			if snapshot then
				local state=getState(fresh)
				state.snapshot=snapshot
			end
		end

		task.wait(0.35)
	end
end

local function showBestMove(id)
	if processing then return end

	processing=true

	local data,board=getBestMoveWithRetry(id)

	if id~=updateId then
		processing=false
		return
	end

	if not data or not board then
		processing=false
		return
	end

	local currentBoard=MatchClient.currentMatch

	if currentBoard~=board or not board.boardExists then
		processing=false
		return
	end

	local team=getTeam(board)

	if team==nil or board.activeTeam~=team then
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

	if board and board.boardExists then
		initializeState(board)
		before=getSnapshot(board)

		local team=getTeam(board)

		if team~=nil and board.activeTeam==team then
			clearHighlights()
			updateId+=1
		end
	end

	local result=oldProcessRound(self,piece,to,info)

	local newBoard=MatchClient.currentMatch

	if newBoard and newBoard.boardExists then
		local after=getSnapshot(newBoard)

		if newBoard==board and before and after then
			updateMoveState(newBoard,before,after)
		else
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

game.ReplicatedStorage.Connections.StartGame.OnClientEvent:Connect(function()
	table.clear(states)

	local board=MatchClient.currentMatch

	if board then
		initializeState(board)
	end

	update()
end)

game.ReplicatedStorage.Connections.EndGame.OnClientEvent:Connect(function()
	updateId+=1
	processing=false
	clearHighlights()
	table.clear(states)
end)

task.defer(function()
	local board=MatchClient.currentMatch

	if board then
		initializeState(board)
		update()
	end
end)
