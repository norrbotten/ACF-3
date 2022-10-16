local ACF = ACF

ACF.Plot = ACF.Plot or {}

local Plot = ACF.Plot

-- DataFrame is like an excel sheet, it has columns with rows, they can reference each other as
-- long as they don't create circular references

local DataFrame_UnaryOps = {}
local DataFrame_BinaryOps = {}
local DataFrame_Functions = {}

local function RegisterDataFrameUnaryOp(OperatorName, Operator, Precedence, Func)
	DataFrame_UnaryOps[OperatorName] = {
		Operator = Operator,
		Precedence = Precedence,
		Func = Func,
	}
end

local function RegisterDataFrameBinaryOp(OperatorName, Operator, Precedence, Associativity, Func)
	DataFrame_BinaryOps[OperatorName] = {
		Operator = Operator,
		Precedence = Precedence,
		Associativity = Associativity,
		Func = Func,
	}
end

RegisterDataFrameUnaryOp("NEGATE", "-", 1, function(Df, Arg)
	return -1 * Arg
end)

RegisterDataFrameBinaryOp("ADD", "+", false, 1, function(Df, Lhs, Rhs)
	return Lhs + Rhs
end)

RegisterDataFrameBinaryOp("SUB", "-", false, 1, function(Df, Lhs, Rhs)
	return Lhs - Rhs
end)

RegisterDataFrameBinaryOp("MUL", "*", false, 2, function(Df, Lhs, Rhs)
	return Lhs * Rhs
end)

RegisterDataFrameBinaryOp("DIV", "/", false, 2, function(Df, Lhs, Rhs)
	return Lhs / Rhs
end)

RegisterDataFrameBinaryOp("POW", "^", false, 3, function(Df, Lhs, Rhs)
	return math.pow(Lhs, Rhs)
end)

local DataFrame = {
	AddColumn = function(self, Name)
		self.ColumnIndex[#table.GetKeys(self.ColumnIndex) + 1] = Name
		self.Columns[Name] = {
			Type = "DATA",
			Values = {},
		}
	end,

	-- A computed column returns FuncG(self, FuncF(self, CellIndex)) when retrieved
	-- FuncG can be nil, then returns FuncF(self, CellIndex)
	AddComputedColumn = function(self, Name, FuncG, FuncF)
		self.ColumnIndex[#table.GetKeys(self.ColumnIndex) + 1] = Name
		self.Columns[Name] = {
			Type = "COMPUTED",
			FuncG = FuncG,
			FuncF = FuncF,
		}
	end,

	GetColumnTable = function(self, Name)
		return self.Columns[Name]
	end,

	-- Checks if a column is continous, ie. it must start at CellIndex=1, and have
	-- valid values throughout its entire length
	IsColumnContinous = function(self, Name)
		local Column = self:GetColumnTable(Name)
		if not Column then return false end

		if Column.Type == "COMPUTED" then
			return true
		elseif Column.Type == "DATA" then
			local N1 = #table.GetKeys(Column.Values)
			local N2 = #Column.Values

			if N1 ~= N2 then return false end
			
			return Column.Values[1] ~= nil
		end
	end,

	-- Checks if a cell ultimately contains a circular reference
	-- Warning: Cells with NATIVE functions can still create circular refs,
	-- (for example a native function calling evaluate on the same cell in the function)
	-- This could be solved by tracking visited cell tables when evaluating a cell,
	-- but i do not like the performance impact of that.
	HasCircularReference = function(self, ColumnName, Cell)
		local Column = self:GetColumnTable(ColumnName)
		if not Column then return false end

		local Cell = Column[CellIndex]
		if not Cell then return false end

		local Visited = {}
		local FoundCircularReference = false

		local function Visit(Cell)
			if not Cell then return end
			if FoundCircularReference then return end

			local Type = type(Cell)
			if Type != "table" then return end

			-- not really sure if using the address to track cells is fine,
			-- some unique ID number could be used instead but this seems to work
			local Addr = ("%p"):format(Cell)

			if Visited[Addr] then
				FoundCircularReference = true
				return
			end

			Visited[Addr] = true

			local OpType = Cell.OperatorType

			if OpType == "UNARY" then
				Visit(Cell.Children[1])

			elseif OpType == "BINARY" then
				Visit(Cell.Children[1])
				Visit(Cell.Children[2])
			
			elseif OpType == "NATIVE" then
				for _, Child in pairs(Cell.Children) do
					Visit(Child)
				end
			end
		end

		return FoundCircularReference
	end,

	-- Gets the length of a column, only continous data columns have a valid length
	GetColumnLength = function(self, ColumnName)
		local Column = self:GetColumnTable(Name)
		if not Column then return end

		if Column.Type != "DATA" then return end
		if not self:IsColumnContinous(ColumnName) then return end

		return #table.GetKeys(Column.Values)
	end,

	-- Iterates over a continous column, calling Func callback for each cell
	DoColumnMap = function(self, ColumnName, StartCellIndex, EndCellIndex, Func, Init)
		local Column = self:GetColumnTable(ColumnName)

		if not Column then return end
		if not self:IsColumnContinous(ColumnName) then return end

		if StartCellIndex == nil then StartCellIndex = 1 end
		if EndCellIndex == nil then EndCellIndex = self:GetColumnLength(ColumnName) end

		if EndCellIndex == nil then return end -- if its still nil we cant run map over this column

		local I = StartCellIndex
		local Value = Init or 0

		while I <= EndCellIndex do
			Value = Func(Value, Column.Values[I])
			I = I + 1
		end

		return Value
	end,

	-- Returns the sum of a continous column
	GetColumnSum = function(self, ColumnName, StartCellIndex, EndCellIndex)
		return self:DoColumnMap(ColumnName, StartCellIndex, EndCellIndex,
								function(Old, Value)
									return Old + Value
								end,
								0)
	end,

	-- Returns the final value of a cell
	EvaluateCell = function(self, Cell)
		local Type = type(Cell)

		if Type == "table" then
			local OpType = Cell.OperatorType

			if OpType == "UNARY" then
				local Op = DataFrame_UnaryOps[Cell.Operator]
				if Op then
					local LHS = self:EvaluateCell(Cell.Children[0])
					return Op.Func(self, LHS)
				end
			elseif OpType == "BINARY" then
				local Op = DataFrame_BinaryOps[Cell.Operator]
				if Op then
					local Lhs = self:EvaluateCell(Cell.Children[0])
					local Rhs = self:EvaluateCell(Cell.Children[1])
					return Op.Func(self, Lhs, Rhs)
				end
			elseif OpType == "NATIVE" then
				local Args = { self }
				for _, Child in pairs(Cell.Children) do
					table.insert(Args, self:EvaluateCell(Child))
				end
				return Cell.Func(unpack(Args))
			end
		elseif Type == "string" then -- a string, can be either a value or a cell reference
			if Cell:StartWith("{") and Cell:EndsWith("}") then -- its a reference
				local Column, Row = unpack(Cell:sub(2, -2):Split(":"))
				if Column == nil or Row == nil then return end

				if tonumber(Column) ~= nil then -- columns can be by index too
					Column = tonumber(Column)
				end

				Row = tonumber(Row)

				if type(Column) == "number" then
					if self.ColumnIndex[Column] then
						Column = self.ColumnIndex[Column]
					else
						return
					end
				end

				if type(Row) != "number" then return end

				return self:EvaluateCellAt(Column, Row)
			else
				return Cell -- a raw value
			end
		elseif Type == "number" then -- cell is a raw data value
			return Cell
		end
	end,

	-- Returns a cell table, or if the column is computed it evaluates it
	GetCellAt = function(self, ColumnName, CellIndex)
		local Column = self:GetColumnTable(ColumnName)
		if not Column then return end

		if Column.Type == "COMPUTED" then
			if Column.FuncG == nil then
				return Column.FuncF(self, CellIndex)
			else
				return Column.FuncF(self, Column.FuncG(self, CellIndex))
			end
		elseif Column.Type == "DATA" then
			local Cell = Column[CellIndex]
			if not Cell then return end

			return Cell
		end
	end,

	-- Evaluates a cell in given colum at index
	EvaluateCellAt = function(self, ColumnName, CellIndex)
		local Cell = self:GetCellAt(ColumnName, CellIndex)
		if not Cell then return end

		return self:EvaluateCell(Cell)
	end,
}

DataFrame.Create = function()
	return setmetatable({
		ColumnIndex = {},
		Columns = {},
	}, DataFrame)
end

DataFrame.__index = DataFrame

Plot.DataFrame = DataFrame

-- Data view is an immutable (not really, since this is lua after all) view into a column in a data
-- frame. It starts and ends at specified indices and provides caching. Can be used for plotting
-- values or for example getting data out of a computed column in a certain range easily.
local DataView = {
	IsValid = function(self)
		if self.Df == nil then return end
		if self.Column == nil then return false end
		if self.End < self.Start then return false end
		return true
	end,

	-- Updates the views cache with values
	Update = function(self)
		if not self:IsValid() then return end

		self.DataCache = {}
		self.VarCache = {}

		local Min = math.huge
		local Max = -math.huge

		for I = self.Start, self.End do
			local Val = self.Df:EvaluateCellAt(self.ColumnName, I)
			self.DataCache[I - self.Start + 1] = Val

			if Val < Min then Min = Val end
			if Val > Max then Max = Val end
		end

		self.VarCache.Min = Min
		self.VarCache.Max = Max
	end,

	GetLength = function(self)
		return self.End - self.Start + 1
	end,

	GetMax = function(self)
		if self.VarCache == nil then self:Update() end
		return self.VarCache.Max
	end,

	GetMin = function(self)
		if self.VarCache == nil then self:Update() end
		return self.VarCache.Min
	end,

	-- Gets a value from the view, indexed from the start of the view
	GetValue = function(self, I)
		if I < 1 or I > (self.End - self.Start) + 1 then return end

		if self.DataCache == nil then self:Update() end

		local Val = self.DataCache[I + self.Start - 1]
		return Val
	end,

	-- Returns the views cache
	GetValues = function(self)
		if self.DataCache == nil then self:Update() end
		return self.DataCache
	end
}

DataView.Create = function(Df, ColumnName, StartCellIndex, EndCellIndex)
	return setmetatable({
		Df         = Df,
		Column     = Df:GetColumnTable(ColumnName),
		ColumnName = ColumnName,

		Start = StartCellIndex or 1,
		End   = EndCellIndex or Df:GetColumnLength(ColumnName) or 0,

		DataCache = nil,
		VarCache  = nil,
		
	}, DataView)
end

DataView.__index = DataView

Plot.DataView = DataView

-- Table of valid plot types
-- false = unimplemented, but there for future reference
local ValidPlotTypes = {}
ValidPlotTypes["2d-line"] = true

-- Required keys in Args table to PlotController:AddPlot
-- Optionals are commented out, but there for reference
local RequiredPlotArgs = {
	-- Shared args:
	-- Color = "Color", -- Default: Color(255, 0, 0), color to draw the line or whatever
	["2d-line"] = {
		SeriesX = "table",       -- DataView for X data
		SeriesY = "table",       -- DataView for Y data
		--SeriesXMin = "number", -- Default: min(SeriesX)
		--SeriesXMax = "number", -- Default: max(SeriesX)
		--SeriesYMin = "number", -- Default: min(SeriesY)
		--SeriesYMin = "number", -- Default: max(SeriesY)
		--Line = "number",       -- Default: 1, thiccness of line
		--Dots = "number",       -- Default: 0, size of data point dots
	}
}

local function Draw2DLinePlot(Width, Height, SeriesX, SeriesY, Args)
	surface.SetDrawColor(Args.Color)

	local I = 1
	local Len = math.min(SeriesX:GetLength(), SeriesY:GetLength())

	local LastX = math.Remap(SeriesX:GetValue(I), Args.SeriesXMin, Args.SeriesXMax, 0, Width)
	local LastY = math.Remap(SeriesY:GetValue(I), Args.SeriesYMin, Args.SeriesYMax, Height, 0)

	I = I + 1

	while I <= Len do
		local X = math.Remap(SeriesX:GetValue(I), Args.SeriesXMin, Args.SeriesXMax, 0, Width)
		local Y = math.Remap(SeriesY:GetValue(I), Args.SeriesYMin, Args.SeriesYMax, Height, 0)

		if isnumber(Args.Line) and Args.Line > 0 then
			surface.DrawLine(LastX, LastY, X, Y)
		end

		if isnumber(Args.Dots) and Args.Dots > 0 then
			surface.DrawCircle(X, Y, Args.Dots, Args.Color.r, Args.Color.g, Args.Color.b)
		end

		LastX = X
		LastY = Y

		I = I + 1
	end
end

local PlotController = {
	AddPlot = function(self, Type, Args)
		if not ValidPlotTypes[Type] then return end

		local RequiredArgs = RequiredPlotArgs[Type]
		if RequiredArgs then
			for Arg, ArgType in pairs(RequiredArgs) do
				print(Arg, ArgType, Args[Arg], type(Args[Arg]))
				if Args[Arg] == nil then return end
				if type(Args[Arg]) ~= ArgType then return end
			end
		end

		-- Set up default vars, and series table
		-- This should really be done in a better way later

		local Series = {}

		if Args.Color == nil or type(Args.Color) ~= "table" then
			Args.Color = Color(255, 0, 0)
		end

		if Type == "2d-line" then
			Series = { Args.SeriesX, Args.SeriesY }

			if Args.SeriesXMin == nil or type(Args.SeriesXMin) ~= "number" then
				Args.SeriesXMin = Args.SeriesX:GetMin()
			end

			if Args.SeriesXMax == nil or type(Args.SeriesXMax) ~= "number" then
				Args.SeriesXMax = Args.SeriesX:GetMax()
			end

			if Args.SeriesYMin == nil or type(Args.SeriesYMin) ~= "number" then
				Args.SeriesYMin = Args.SeriesY:GetMin()
			end

			if Args.SeriesYMax == nil or type(Args.SeriesYMax) ~= "number" then
				Args.SeriesYMax = Args.SeriesY:GetMax()
			end
		end

		table.insert(self.Plots, {
			PlotType = Type,
			Series = Series,
			Args = Args,
		})

		return #self.Plots
	end,

	GetPlotXMinMax = function(self, Plot)
		local P = self.Plots[Plot]
		if not P then return end

		if P.PlotType == "2d-line" then
			return P.Args.SeriesXMin, P.Args.SeriesXMax
		end
	end,

	GetPlotYMinMax = function(self, Plot)
		local P = self.Plots[Plot]
		if not P then return end

		if P.PlotType == "2d-line" then
			return P.Args.SeriesYMin, P.Args.SeriesYMax
		end
	end,

	GetUnifiedXMinMax = function(self)
		local Min = math.huge
		local Max = -math.huge

		for I = 1, #self.Plots do
			local PMin, PMax = self:GetPlotXMinMax(I)
			if PMin < Min then Min = PMin end
			if PMax > Max then Max = PMax end
		end

		return Min, Max
	end,

	GetUnifiedYMinMax = function(self)
		local Min = math.huge
		local Max = -math.huge

		for I = 1, #self.Plots do
			local PMin, PMax = self:GetPlotYMinMax(I)
			if PMin < Min then Min = PMin end
			if PMax > Max then Max = PMax end
		end

		return Min, Max
	end,

	SetXLabel = function(Label)
		if not isstring(Label) then return end
		self.XLabel = Label
	end,

	SetYLabel = function(Label)
		if not isstring(Label) then return end
		self.YLabel = Label
	end,

	Draw = function(self, Width, Height)
		for _, Plot in pairs(self.Plots) do
			if Plot.PlotType == "2d-line" then
				Draw2DLinePlot(Width, Height, Plot.Series[1], Plot.Series[2], Plot.Args)
			end
		end

		if isstring(self.XLabel) and #self.XLabel > 0 then

		end

		if isstring(self.YLabel) and #self.YLabel > 0 then

		end
	end,
}

PlotController.Create = function()
	return setmetatable({
		Plots = {},
		XLabel = "",
		YLabel = "",
	}, PlotController)
end

PlotController.__index = PlotController

Plot.PlotController = PlotController
