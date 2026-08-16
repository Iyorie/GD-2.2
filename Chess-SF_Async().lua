local Players=game:GetService("Players")
local HttpService=game:GetService("HttpService")
local RunService=game:GetService("RunService")
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

local highlightConnection

local function clearHighlights()
	if highlightConnection then
		highlightConnection:Disconnect()
		highlightConnection=nil
	end

	for _,v in pairs(highlights) do
		if v then
			v:Destroy()
		end
	end

	table.clear(highlights)
end

local function lerpColor(a,b,t)
	return a:Lerp(b,t)
end

local function gradientColor(colors,t)
	local count=#colors
	local pos=(t%(count))/1
	local index=math.floor(pos)+1
	local nextIndex=index%count+1
	local alpha=pos-math.floor(pos)

	return lerpColor(colors[index],colors[nextIndex],alpha)
end

local function highlightTile(tile,kind)
	if not tile then return end

	local v=Instance.new("SelectionBox")
	v.SurfaceTransparency=0.2
	v.Transparency=0
	v.LineThickness=0.12
	v.Adornee=tile
	v.Parent=tile

	table.insert(highlights,v)

	if not highlightConnection then
		local start=os.clock()

		highlightConnection=RunService.RenderStepped:Connect(function()
			if #highlights==0 then
				highlightConnection:Disconnect()
				highlightConnection=nil
				return
			end

			local t=(os.clock()-start)*0.35

			for i,h in ipairs(highlights) do
				if h and h.Parent then
					local colors

					if h:GetAttribute("kind")=="from" then
						colors={
							Color3.fromRGB(0,255,255),
							Color3.fromRGB(80,120,255),
							Color3.fromRGB(180,70,255),
							Color3.fromRGB(0,255,255)
						}
					else
						colors={
							Color3.fromRGB(255,230,70),
							Color3.fromRGB(255,140,40),
							Color3.fromRGB(255,70,170),
							Color3.fromRGB(255,230,70)
						}
					end

					local color=gradientColor(colors,t+(i-1)*0.15)

					h.Color3=color
					h.SurfaceColor3=color
				end
			end
		end)
	end

	v:SetAttribute("kind",kind or "to")
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
	if type(x)~="number" or type(y)~="number" then return end
	if x<1 or x>8 or y<1 or y>8 then return end
	return FILES[9-x]..y
end

local function findTile(board,x,y)
	return board.tiles[x] and board.tiles[x][y]
end

--[[local function highlightTile(tile,color)
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
end]]

local function getTeam(board)
	if not board or not board.players then return end
	if board.players[true]==player then return true end
	if board.players[false]==player then return false end
end

local function getState(board)
	local key=tostring(board)

	if not states[key] then
		states[key]={
			half=0,
			full=1,
			ep="-",
			snapshot=nil,
			lastMover=nil,
			ready=false
		}
	end

	return states[key]
end

local function getSnapshot(board)
	if not board or not board.boardExists then return end

	local snap={}
	local whiteKing=0
	local blackKing=0
	local pieces=0

	for y=1,8 do
		for x=1,8 do
			local piece=board:getPiece({x,y})

			if piece then
				local key=x..":"..y

				snap[key]={
					ref=piece,
					name=piece.Name,
					team=piece.team,
					x=x,
					y=y,
					unmoved=type(piece.isUnmoved)=="function" and piece:isUnmoved() or piece.unmoved==true
				}

				pieces+=1

				if piece.Name=="King" then
					if piece.team then
						whiteKing+=1
					else
						blackKing+=1
					end
				end
			end
		end
	end

	return snap,whiteKing,blackKing,pieces
end

local function getPieceAt(snapshot,x,y)
	return snapshot and snapshot[x..":"..y]
end

local function samePiece(a,b)
	if not a or not b then return false end
	return a.ref==b.ref
end

local function getMovedPiece(before,after,mover)
	if not before or not after or mover==nil then return end

	local oldPiece
	local newPiece
	local candidates=0

	for key,old in pairs(before) do
		if old.team==mover then
			local current=after[key]

			if not current or not samePiece(old,current) then
				if not oldPiece then
					oldPiece=old
				else
					candidates+=1
				end
			end
		end
	end

	for key,new in pairs(after) do
		if new.team==mover then
			local old=before[key]

			if not old or not samePiece(old,new) then
				if not newPiece then
					newPiece=new
				else
					candidates+=1
				end
			end
		end
	end

	if not oldPiece or not newPiece then return end
	if candidates>0 then return end

	return oldPiece,newPiece
end

local function wasCapture(before,after,old,new)
	if not before or not after or not old or not new then return false end

	local destination=before[new.x..":"..new.y]

	if destination and destination.team~=old.team then
		return true
	end

	local removed=0

	for key,piece in pairs(before) do
		if not after[key] and not (piece.x==old.x and piece.y==old.y) then
			removed+=1
		end
	end

	return removed>0
end

local function getCastling(board)
	local wk=board:getPiece({5,1})
	local wra=board:getPiece({8,1})
	local wrh=board:getPiece({1,1})
	local bk=board:getPiece({5,8})
	local bra=board:getPiece({8,8})
	local brh=board:getPiece({1,8})

	local function unmoved(piece,team,name)
		if not piece or piece.team~=team or piece.Name~=name then
			return false
		end

		if type(piece.isUnmoved)=="function" then
			return piece:isUnmoved()==true
		end

		return piece.unmoved==true
	end

	local v=""

	if unmoved(wk,true,"King") and unmoved(wra,true,"Rook") then
		v="K"
	end

	if unmoved(wk,true,"King") and unmoved(wrh,true,"Rook") then
		v=v.."Q"
	end

	if unmoved(bk,false,"King") and unmoved(bra,false,"Rook") then
		v=v.."k"
	end

	if unmoved(bk,false,"King") and unmoved(brh,false,"Rook") then
		v=v.."q"
	end

	return v=="" and "-" or v
end

local function getEnPassant(after,old,new)
	if not old or not new or old.name~="Pawn" then return "-" end

	if old.x~=new.x then return "-" end
	if math.abs(new.y-old.y)~=2 then return "-" end

	local dir=old.team and 1 or -1
	local targetY=old.y+dir

	if targetY<1 or targetY>8 then
		return "-"
	end

	for _,x in ipairs({new.x-1,new.x+1}) do
		if x>=1 and x<=8 then
			local enemy=getPieceAt(after,x,new.y)

			if enemy and enemy.name=="Pawn" and enemy.team~=old.team then
				local target=gridToAlgebraic(new.x,targetY)

				if target then
					return target
				end
			end
		end
	end

	return "-"
end

local function updateMoveState(board,before,after,mover)
	if not board or not before or not after or mover==nil then return end

	local state=getState(board)
	local old,new=getMovedPiece(before,after,mover)

	state.ep="-"

	if not old or not new then
		state.snapshot=after
		state.lastMover=mover
		return
	end

	local capture=wasCapture(before,after,old,new)

	if old.name=="Pawn" or capture then
		state.half=0
	else
		state.half=(tonumber(state.half) or 0)+1
	end

	state.ep=getEnPassant(after,old,new)

	if mover==false then
		state.full=(tonumber(state.full) or 1)+1
	end

	state.lastMover=mover
	state.snapshot=after
	state.ready=true
end

local function initializeState(board)
	if not board or not board.boardExists then return end

	local state=getState(board)

	if state.ready and state.snapshot then
		return
	end

	local snapshot,wk,bk=getSnapshot(board)

	if not snapshot or wk~=1 or bk~=1 then
		return
	end

	state.snapshot=snapshot
	state.half=tonumber(board.fiftyMoveCounter) or 0
	state.full=math.max(1,math.ceil((tonumber(board.round) or 1)/2))
	state.ep="-"
	state.ready=true
end

local function buildFen(board)
	if not board or not board.boardExists then return end

	local snapshot,wk,bk=getSnapshot(board)

	if not snapshot or wk~=1 or bk~=1 then
		return
	end

	local state=getState(board)

	if not state.ready then
		initializeState(board)
	end

	if not state.ready then
		return
	end

	local rows={}

	for y=8,1,-1 do
		local row=""
		local empty=0

		for x=8,1,-1 do
			local piece=snapshot[x..":"..y]

			if piece then
				if empty>0 then
					row..=tostring(empty)
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
			row..=tostring(empty)
		end

		rows[#rows+1]=row
	end

	local active=board.activeTeam and "w" or "b"
	local castling=getCastling(board)
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

	half=tonumber(half)
	full=tonumber(full)

	if not half or not full then return false end
	if half<0 or full<1 then return false end

	local ranks={}
	for rank in board:gmatch("[^/]+") do
		ranks[#ranks+1]=rank
	end

	if #ranks~=8 then return false end

	local wk,bk=0,0

	for _,rank in ipairs(ranks) do
		local count=0

		for i=1,#rank do
			local c=rank:sub(i,i)

			if c:match("%d") then
				local n=tonumber(c)

				if not n or n<1 or n>8 then
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

		local snapshot,wk,bk=getSnapshot(board)

		if snapshot and wk==1 and bk==1 then
			local state=getState(board)

			if not state.ready then
				initializeState(board)
			end

			local fen=buildFen(board)

			if fen and validateFen(fen) then
				return fen,board,snapshot
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

	if not response or type(response.Body)~="string" or response.Body=="" then
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

local function recoverState(board)
	if not board or not board.boardExists then return end

	local snapshot,wk,bk=getSnapshot(board)

	if not snapshot or wk~=1 or bk~=1 then return end

	local state=getState(board)

	state.snapshot=snapshot
	state.ep="-"
	state.half=tonumber(board.fiftyMoveCounter) or state.half or 0
	state.full=math.max(1,math.ceil((tonumber(board.round) or 1)/2))
	state.ready=true
end

local function getBestMoveWithRetry(id)
	local rejected={}
	local attempts=0

	while id==updateId do
		local fen,board,snapshot=getFreshFen(id)

		if not fen or not board or not snapshot then
			return
		end

		if rejected[fen] then
			recoverState(board)
			task.wait(0.2)
			continue
		end

		local data=requestBestMove(fen)

		if data then
			return data,board,snapshot
		end

		rejected[fen]=true
		attempts+=1

		if attempts>=3 then
			recoverState(board)
			attempts=0
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

	local fx,fy=algebraicToGrid(data.from)
	local tx,ty=algebraicToGrid(data.to)

	if not fx or not fy or not tx or not ty then
		processing=false
		return
	end

	local piece=snapshot[fx..":"..fy]

	if not piece or piece.team~=team then
		processing=false
		return
	end

	local fromTile=findTile(board,fx,fy)
	local toTile=findTile(board,tx,ty)

	if not fromTile or not toTile then
		processing=false
		return
	end

	clearHighlights()

	highlightTile(fromTile,"from")
highlightTile(toTile,"to")

	print("[BestMove]",data.from.." -> "..data.to,data.san or "")

	processing=false
end

local function update()
	updateId+=1

	local id=updateId

	clearHighlights()

	task.spawn(function()
		task.wait()

		if id~=updateId then return end

		showBestMove(id)
	end)
end

local oldProcessRound=MatchClient.processRound

MatchClient.processRound=function(self,piece,to,info)
	local board=MatchClient.currentMatch
	local before
	local mover

	if board and board.boardExists then
		initializeState(board)
		before=getSnapshot(board)
		mover=board.activeTeam

		local team=getTeam(board)

		if team~=nil and board.activeTeam==team then
			clearHighlights()
			updateId+=1
		end
	end

	local ok,result=pcall(function()
		return oldProcessRound(self,piece,to,info)
	end)

	if not ok then
		processing=false
		warn("[BestMove] processRound:",result)
		return
	end

	local newBoard=MatchClient.currentMatch

	if newBoard and newBoard.boardExists then
		local after=getSnapshot(newBoard)

		if newBoard==board and before and after and mover~=nil then
			updateMoveState(newBoard,before,after,mover)
		elseif after then
			local state=getState(newBoard)
			state.snapshot=after
			state.ready=true
			state.ep="-"
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
						local snapshot,wk,bk=getSnapshot(board)

						if snapshot and wk==1 and bk==1 then
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
			local snapshot,wk,bk=getSnapshot(board)

			if snapshot and wk==1 and bk==1 then
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
