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
				return Column.FuncG(self, Column.FuncF(self, CellIndex))
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
