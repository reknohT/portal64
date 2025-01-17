local static_export = require('tools.level_scripts.static_export')
local collision_export = require('tools.level_scripts.collision_export')
local sk_input = require('sk_input')
local sk_math = require('sk_math')
local sk_mesh = require('sk_mesh')
local sk_definition_writer = require('sk_definition_writer')
local dynamic_collision_export = require('tools.level_scripts.dynamic_collision_export')

local portal_surfaces = {}

local static_to_portable_surface_mapping = {}
local portal_surfaces = {}

local function calculate_surface_basis(mesh)
    local normal = sk_math.vector3(0, 0, 0)

    for _, vertex_normal in pairs(mesh.normals) do
        normal = normal + vertex_normal
    end

    normal = normal:normalized()
    local right;
    local up;

    if (math.abs(normal.z) < 0.7) then
        right = sk_math.vector3(0, 0, 1):cross(normal)
        right = right:normalized()
        up = normal:cross(right)
    else
        right = sk_math.vector3(1, 0, 0):cross(normal)
        right = right:normalized()
        up = normal:cross(right)
    end

    return right, up, normal
end

local FIXED_POINT_PRECISION = 8
local FIXED_POINT_SCALAR = (1 << FIXED_POINT_PRECISION)

local function to_local_coords(origin, edge_a, edge_b, input)
    local relative = input - origin

    return math.floor(relative:dot(edge_a) * FIXED_POINT_SCALAR + 0.5), math.floor(relative:dot(edge_b) * FIXED_POINT_SCALAR + 0.5)
end

local function level_edge_key(a, b)
    return (math.max(a, b) << 8) | math.min(a, b)
end

local function get_edge_index(edges, edge_key)
    local result = edges[edge_key]

    if result then
        return result.edge_index
    end

    return 0xFF
end

local function calculate_portal_single_surface(mesh, mesh_display_list)
    local origin = mesh.bb:lerp(0.5)

    local right, up, normal = calculate_surface_basis(mesh)

    local vertices = {}

    for _, vertex in pairs(mesh.vertices) do
        local x, y = to_local_coords(origin, right, up, vertex)
        table.insert(vertices, {{{x = x, y = y}}})
    end

    sk_definition_writer.add_definition(mesh.name .. '_portal_mesh', 'struct Vector2s16[]', '_geo', vertices)

    local edges = {}
    local edge_for_points = {}

    for _, face in pairs(mesh.faces) do
        local edge_keys = {}
        local is_reverse_edge = {}

        for index_index, current_index in pairs(face) do
            local next_index = face[index_index % #face + 1]

            local key = level_edge_key(current_index, next_index)

            local edge_index = #edges
            local next_index
            local prev_index

            if index_index == 1 then
                next_index = edge_index + 1
                prev_index = edge_index + #face - 1
            elseif index_index == #face then
                next_index = edge_index - #face + 1
                prev_index = edge_index - 1
            else
                next_index = edge_index + 1
                prev_index = edge_index - 1
            end

            local edge = {
                pointIndex = current_index - 1,
                nextEdge = next_index,
                prevEdge = prev_index,
                reverseEdge = 0xFF
            }

            table.insert(edges, edge)

            if edge_for_points[key] then
                local reverseEdge = edges[edge_for_points[key] + 1]

                reverseEdge.reverseEdge = edge_index
                edge.reverseEdge = edge_for_points[key]

                edge_for_points[key] = nil
            else
                edge_for_points[key] = edge_index
            end
        end
    end

    sk_definition_writer.add_definition(mesh.name .. "_portal_edges", "struct SurfaceEdge[]", "_geo", edges)

    return {
        vertices = sk_definition_writer.reference_to(vertices, 1),
        edges = sk_definition_writer.reference_to(edges, 1),
        edgeCount = #edges,
        vertexCount = #vertices,
        shouldCleanup = 0,

        right = right,
        up = up,
        corner = origin,

        gfxVertices = sk_mesh.generate_vertex_buffer(mesh, mesh.material, "_geo"),
        triangles = mesh_display_list,
    };
end

for _, surface in pairs(static_export.static_nodes) do
    if surface.accept_portals then
        table.insert(static_to_portable_surface_mapping, #portal_surfaces)
        table.insert(portal_surfaces, calculate_portal_single_surface(surface.mesh, surface.display_list))
    else
        table.insert(static_to_portable_surface_mapping, -1)
    end
end

sk_definition_writer.add_definition("portal_surfaces", "struct PortalSurface[]", "_geo", portal_surfaces)

local function is_coplanar_portal_surface(quad, mesh, collision_bb)
    if not collision_export.is_coplanar(quad, mesh) then
        return false
    end

    if not mesh.bb:overlaps(collision_bb) then
        return false
    end

    return true
end

local portal_mapping_data = {}
local portal_mapping_range = {}
local dynamic_mapping_range = {}

local mapping_index = 0

for _, quad in pairs(collision_export.colliders) do
    local start_mapping_index = mapping_index

    local collision_with_padding = collision_export.collision_quad_bb(quad)
    collision_with_padding.min = collision_with_padding.min - 0.1
    collision_with_padding.max = collision_with_padding.max + 0.1

    for static_index, surface in pairs(static_export.static_nodes) do
        if not surface.transform_index and surface.accept_portals and is_coplanar_portal_surface(quad, surface.mesh, collision_with_padding) then
            local portal_surface_index = static_to_portable_surface_mapping[static_index]

            if portal_surface_index ~= -1 then
                table.insert(portal_mapping_data, static_to_portable_surface_mapping[static_index])
                mapping_index = mapping_index + 1
            end
        end
    end

    if mapping_index > 255 then
        error("mapping_index was greater than 255")
    end

    table.insert(portal_mapping_range, {start_mapping_index, mapping_index})
end

for _, box in pairs(dynamic_collision_export.dynamic_boxes_original) do
    local start_mapping_index = mapping_index

    for static_index, surface in pairs(static_export.static_nodes) do
        -- simple hack for now. If collider and a portal surface share
        -- the same transform then the portal surface is assumed to be
        -- attached to the collider
        if surface.transform_index == box.parent_node_index then
            local portal_surface_index = static_to_portable_surface_mapping[static_index]

            if portal_surface_index ~= -1 then
                table.insert(portal_mapping_data, static_to_portable_surface_mapping[static_index])
                mapping_index = mapping_index + 1
            end
        end
    end

    if mapping_index > 255 then
        error("mapping_index was greater than 255")
    end

    table.insert(dynamic_mapping_range, {start_mapping_index, mapping_index})
end

sk_definition_writer.add_definition("mapping_indices", "u8[]", "_geo", portal_mapping_data)
sk_definition_writer.add_definition("collider_to_surface", "struct PortalSurfaceMappingRange[]", "_geo", portal_mapping_range)
sk_definition_writer.add_definition("dynamic_collider_to_surface", "struct PortalSurfaceMappingRange[]", "_geo", dynamic_mapping_range)

return {
    portal_surfaces = portal_surfaces,
    portal_mapping_data = portal_mapping_data,
    portal_mapping_range = portal_mapping_range,
    dynamic_mapping_range = dynamic_mapping_range,
}