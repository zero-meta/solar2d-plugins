--- Longer curve (possibly more than one draw call) using an unshared buffer.

--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
-- IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- [ MIT license: http://www.opensource.org/licenses/mit-license.php ]
--

local co3 = require("plugin.customobjects3")
local curve = require("cubic.curve")

--display.setDrawMode("wireframe")
display.setDefault( 'isShaderCompilerVerbose', true )

co3.registerUnsharedDataType() -- in practice, plugin itself would probably do this

print( "Vectors available, roughly:", system.getInfo( "maxUniformVectorsCount" ) ) 

-- Make instancing available.
local VertexTransforms = {
  findAndReplace = {
    ["vec2 a_Position"] = "vec3 a_Position",
    ["( a_Position )"] = "( a_Position.xy )"
  },

  findAndInsertAfter = {
    -- Find this...
    ["v_UserData = a_UserData;"] =

    -- ...then insert this after:
    "\n" ..
    "\tv_InstanceIndex = a_Position.z;\n"
  }
}

local CommonTransforms = {
  findAndReplace = {
    -- Find this...
    ["vec2 v_Position;"] =

    -- ...and replace with:
    "float v_InstanceIndex;\n" ..
    "\n" ..
    "#define CoronaInstanceIndex int( v_InstanceIndex )\n" ..
    "#define CoronaInstanceFloat v_InstanceIndex\n"
  }
}

for k, v in pairs(CommonTransforms) do
  local vv = VertexTransforms[k] or {}

  for fk, fv in pairs(v) do
    vv[fk] = fv
  end

  VertexTransforms[k] = vv
end

graphics.defineShellTransform{ name = "instances", fragmentSource = CommonTransforms, vertexSource = VertexTransforms }

-- Various constants.
local MaxInstances = 20 -- arbitrary, as strictly speaking this method should have no limit

local N = 16 -- number of knot ranges...
local K = N + 1 -- ...and knots

-- The vertex kernel will combine the interpolation, Hermite pairs, and mesh to mold the curve.
graphics.defineEffect{
	category = "generator",
	name = "uv",

	dataType = "unsharedBuffers", details = { supportsInstancing = "z" }, shellTransform = "instances",

	vertex = ([[
		#define NUM_SLOTS %i
	
    uniform P_UV vec4 u_Vectors[NUM_SLOTS * 2 + 8]; // cf. plugin
  
    #define GetUniformVector( INDEX ) u_Vectors[ int( INDEX ) ]
  
		P_POSITION vec2 VertexKernel (P_POSITION vec2 pos)
		{
			// ^^ Could also use pos to free up uvs; must account for centering

			// Precalculated coefficients (t^3, t^2, t, 1) and derivatives, mapped
			// by Hermite "geometry matrix" (just the constant coefficients of
			// the point and tangent equations), at t = xpos / N
      P_UV float xpos = floor(CoronaTexCoord.x * float(NUM_SLOTS - 1) + .5);
			P_POSITION vec4 cpos = GetUniformVector(xpos);
			P_POSITION vec4 ctan = GetUniformVector(xpos + float(NUM_SLOTS));

			// Nodes (point.xy, tangent.xy) follow these coeffs
			P_UV float index = CoronaInstanceFloat + float(2 * NUM_SLOTS);
			P_POSITION vec4 pt1 = GetUniformVector(index);
			P_POSITION vec4 pt2 = GetUniformVector(index + 1.);

			// 2x4 matrix
			P_POSITION vec4 a = vec4(pt1.x, pt2.x, pt1.z, pt2.z);
			P_POSITION vec4 b = vec4(pt1.y, pt2.y, pt1.w, pt2.w);

			// Transpose vector-matrix multiplies
			P_POSITION vec2 p = vec2(dot(cpos, a), dot(cpos, b));
			P_POSITION vec2 t = vec2(dot(ctan, a), dot(ctan, b));

			P_POSITION vec2 f = normalize(t);
			P_POSITION vec2 u = vec2(-f.y, +f.x);

			pos = p + u * 2. * (CoronaTexCoord.y - .5) * 35.;
			
			return pos;
		}
	]]):format(K),
	
	fragment = [[
		P_COLOR vec4 FragmentKernel (P_UV vec2 uv)
		{
			return vec4(uv, 0., 1.);
		}
	]]
}

-- Make a full-screen rect to catch presses.
local back = display.newRect(display.contentCenterX, display.contentCenterY, display.contentWidth, display.contentHeight)

back.isHitTestable, back.isVisible = true, false

-- Create a canonical geometry that will be molded by the curve. The cell sizes
-- are only important for some quick debugging. The (auto-generated) texture
-- coordinates will be how we access the mesh.
local Lattice = {}

local function AddPoint (x, y)
  Lattice[#Lattice + 1] = x
  Lattice[#Lattice + 1] = y
end

local Rows, Cols = 4, 8

for col = 1, Cols do
	for row = 1, Rows do
		local ulx, uly = (col - 1) * 5, (row - 1) * 5
		local urx, ury = col * 5, uly
		local llx, lly = ulx, row * 5
		local lrx, lry = urx, lly

		AddPoint(ulx, uly)
    AddPoint(urx, ury)
    AddPoint(llx, lly)
	  AddPoint(llx, lly)
    AddPoint(urx, ury)
		AddPoint(lrx, lry)
	end
end

-- This object will be instantiated as points are added to its buffer.
local poly = display.newMesh{ vertices = Lattice }

poly:translate(50, 50) -- make it "visible"

poly.fill.effect = "generator.custom.uv"

local buffer = poly.fill.effect.buffer -- owned by effect instance

-- Plot points and sculpt meshes into curve segments spanning them.
local num_points = 0
local x1, y1, x2, y2

back:addEventListener("touch", function(event)
	local phase = event.phase

	if phase == "began" then
		if num_points < MaxInstances + 3 then
			local x, y = event.x, event.y

      num_points = num_points + 1

      -- Once we have three points we can find their Catmull-Rom point / tangent and
      -- repurpose that as one of the Hermite point / tangent pairs in the uniforms.
			if num_points >= 3 then
				buffer:appendVector(x2, y2, x - x1, y - y1)
			end

			x1, y1, x2, y2 = x2, y2, x, y

			display.newCircle(x, y, 5):setFillColor(1, 0, 0)
		end
		
		display.getCurrentStage():setFocus(event.target)
	elseif phase == "ended" or phase == "cancelled" then
		display.getCurrentStage():setFocus(nil)
	end

	return true
end)

-- Precompute some Hermite curve interpolation information. This will make up
-- some of the uniforms.
local function AddUniform (o)
	buffer:appendVector(o.a, o.b, o.c, o.d)
end

local out = {}

for i = 1, K do -- positions
	curve.ComputeCoefficients("hermite", out, nil, (i - 1) / N)

	AddUniform(out)
end

for i = 1, K do -- tangents
	curve.ComputeCoefficients("hermite", nil, out, (i - 1) / N)

	AddUniform(out)
end

-- Lock that information in.
buffer:bakeConstants()