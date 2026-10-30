#[compute]
#version 450

// 2D Conservative Shallow Water Equations (SWE) Compute Shader for Godot 4.4
// Implements HLL approximate Riemann solver and Audusse well-balanced hydrostatic reconstruction.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer BufferInH { float in_h[]; };
layout(set = 0, binding = 1, std430) readonly buffer BufferInQx { float in_qx[]; };
layout(set = 0, binding = 2, std430) readonly buffer BufferInQz { float in_qz[]; };
layout(set = 0, binding = 3, std430) readonly buffer BufferBed { float in_bed[]; };

layout(set = 0, binding = 4, std430) writeonly buffer BufferOutH { float out_h[]; };
layout(set = 0, binding = 5, std430) writeonly buffer BufferOutQx { float out_qx[]; };
layout(set = 0, binding = 6, std430) writeonly buffer BufferOutQz { float out_qz[]; };

layout(push_constant, std430) uniform Params {
    int width;
    int height;
    float dx;
    float dz;
    float dt;
    float gravity;
    float manning_n;
    float h_dry;
    float rain_rate;
    float infil_rate;
    float evap_rate;
    int boundary_type; // 0 = WALL, 1 = OUTFLOW
} params;

// HLL 1D Riemann flux
void hll_flux(float hL, float qnL, float qtL, float unL, float utL,
              float hR, float qnR, float qtR, float unR, float utR,
              float g, float h_dry,
              out float f_h, out float f_qn, out float f_qt) {
    if (hL <= h_dry && hR <= h_dry) {
        f_h = 0.0; f_qn = 0.0; f_qt = 0.0;
        return;
    }
    
    float cL = (hL > 0.0) ? sqrt(g * hL) : 0.0;
    float cR = (hR > 0.0) ? sqrt(g * hR) : 0.0;
    
    float sL, sR;
    if (hL <= h_dry) {
        sL = unR - 2.0 * cR;
        sR = unR + cR;
    } else if (hR <= h_dry) {
        sL = unL - cL;
        sR = unL + 2.0 * cL;
    } else {
        float sqL = sqrt(hL);
        float sqR = sqrt(hR);
        float u_roe = (sqL * unL + sqR * unR) / (sqL + sqR);
        float c_roe = sqrt(0.5 * g * (hL + hR));
        sL = min(unL - cL, u_roe - c_roe);
        sR = max(unR + cR, u_roe + c_roe);
    }
    
    float fL_h = qnL;
    float fL_qn = qnL * unL + 0.5 * g * hL * hL;
    float fL_qt = qnL * utL;
    
    float fR_h = qnR;
    float fR_qn = qnR * unR + 0.5 * g * hR * hR;
    float fR_qt = qnR * utR;
    
    if (sL >= 0.0) {
        f_h = fL_h; f_qn = fL_qn; f_qt = fL_qt;
    } else if (sR <= 0.0) {
        f_h = fR_h; f_qn = fR_qn; f_qt = fR_qt;
    } else {
        float denom = sR - sL;
        if (abs(denom) < 1e-6) {
            f_h = 0.5 * (fL_h + fR_h);
            f_qn = 0.5 * (fL_qn + fR_qn);
            f_qt = 0.5 * (fL_qt + fR_qt);
        } else {
            f_h = (sR * fL_h - sL * fR_h + sL * sR * (hR - hL)) / denom;
            f_qn = (sR * fL_qn - sL * fR_qn + sL * sR * (qnR - qnL)) / denom;
            f_qt = (sR * fL_qt - sL * fR_qt + sL * sR * (qtR - qtL)) / denom;
        }
    }
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= params.width || coord.y >= params.height) {
        return;
    }
    
    int w = params.width;
    int h_res = params.height;
    int idx = coord.y * w + coord.x;
    
    float h_c = in_h[idx];
    float qx_c = in_qx[idx];
    float qz_c = in_qz[idx];
    float b_c = in_bed[idx];
    
    float u_c = (h_c > params.h_dry) ? (qx_c / h_c) : 0.0;
    float v_c = (h_c > params.h_dry) ? (qz_c / h_c) : 0.0;
    
    // ------------------------------------------------------------------------
    // X-Direction Fluxes: East (Right) & West (Left)
    // ------------------------------------------------------------------------
    float fE_h, fE_qx, fE_qz;
    float s_bed_E = 0.0;
    
    if (coord.x < w - 1) {
        int idxE = coord.y * w + (coord.x + 1);
        float h_E = in_h[idxE];
        float b_E = in_bed[idxE];
        float u_E = (h_E > params.h_dry) ? (in_qx[idxE] / h_E) : 0.0;
        float v_E = (h_E > params.h_dry) ? (in_qz[idxE] / h_E) : 0.0;
        
        float b_int = max(b_c, b_E);
        float h_L_star = max(0.0, h_c + b_c - b_int);
        float h_R_star = max(0.0, h_E + b_E - b_int);
        
        hll_flux(h_L_star, h_L_star * u_c, h_L_star * v_c, u_c, v_c,
                 h_R_star, h_R_star * u_E, h_R_star * v_E, u_E, v_E,
                 params.gravity, params.h_dry,
                 fE_h, fE_qx, fE_qz);
        s_bed_E = 0.5 * params.gravity * (h_L_star * h_L_star - h_c * h_c);
    } else {
        if (params.boundary_type == 0) { // WALL
            fE_h = 0.0; fE_qx = 0.5 * params.gravity * h_c * h_c; fE_qz = 0.0;
        } else { // OUTFLOW
            fE_h = qx_c; fE_qx = qx_c * u_c + 0.5 * params.gravity * h_c * h_c; fE_qz = qz_c * u_c;
        }
    }
    
    float fW_h, fW_qx, fW_qz;
    float s_bed_W = 0.0;
    
    if (coord.x > 0) {
        int idxW = coord.y * w + (coord.x - 1);
        float h_W = in_h[idxW];
        float b_W = in_bed[idxW];
        float u_W = (h_W > params.h_dry) ? (in_qx[idxW] / h_W) : 0.0;
        float v_W = (h_W > params.h_dry) ? (in_qz[idxW] / h_W) : 0.0;
        
        float b_int = max(b_W, b_c);
        float h_L_star = max(0.0, h_W + b_W - b_int);
        float h_R_star = max(0.0, h_c + b_c - b_int);
        
        hll_flux(h_L_star, h_L_star * u_W, h_L_star * v_W, u_W, v_W,
                 h_R_star, h_R_star * u_c, h_R_star * v_c, u_c, v_c,
                 params.gravity, params.h_dry,
                 fW_h, fW_qx, fW_qz);
        s_bed_W = 0.5 * params.gravity * (h_c * h_c - h_R_star * h_R_star);
    } else {
        if (params.boundary_type == 0) { // WALL
            fW_h = 0.0; fW_qx = 0.5 * params.gravity * h_c * h_c; fW_qz = 0.0;
        } else { // OUTFLOW
            fW_h = qx_c; fW_qx = qx_c * u_c + 0.5 * params.gravity * h_c * h_c; fW_qz = qz_c * u_c;
        }
    }
    
    // ------------------------------------------------------------------------
    // Z-Direction Fluxes: South (Bottom) & North (Top)
    // ------------------------------------------------------------------------
    float fS_h, fS_qx, fS_qz;
    float s_bed_S = 0.0;
    
    if (coord.y < h_res - 1) {
        int idxS = (coord.y + 1) * w + coord.x;
        float h_S = in_h[idxS];
        float b_S = in_bed[idxS];
        float u_S = (h_S > params.h_dry) ? (in_qx[idxS] / h_S) : 0.0;
        float v_S = (h_S > params.h_dry) ? (in_qz[idxS] / h_S) : 0.0;
        
        float b_int = max(b_c, b_S);
        float h_T_star = max(0.0, h_c + b_c - b_int);
        float h_B_star = max(0.0, h_S + b_S - b_int);
        
        hll_flux(h_T_star, h_T_star * v_c, h_T_star * u_c, v_c, u_c,
                 h_B_star, h_B_star * v_S, h_B_star * u_S, v_S, u_S,
                 params.gravity, params.h_dry,
                 fS_h, fS_qz, fS_qx);
        s_bed_S = 0.5 * params.gravity * (h_T_star * h_T_star - h_c * h_c);
    } else {
        if (params.boundary_type == 0) { // WALL
            fS_h = 0.0; fS_qx = 0.0; fS_qz = 0.5 * params.gravity * h_c * h_c;
        } else { // OUTFLOW
            fS_h = qz_c; fS_qx = qx_c * v_c; fS_qz = qz_c * v_c + 0.5 * params.gravity * h_c * h_c;
        }
    }
    
    float fN_h, fN_qx, fN_qz;
    float s_bed_N = 0.0;
    
    if (coord.y > 0) {
        int idxN = (coord.y - 1) * w + coord.x;
        float h_N = in_h[idxN];
        float b_N = in_bed[idxN];
        float u_N = (h_N > params.h_dry) ? (in_qx[idxN] / h_N) : 0.0;
        float v_N = (h_N > params.h_dry) ? (in_qz[idxN] / h_N) : 0.0;
        
        float b_int = max(b_N, b_c);
        float h_T_star = max(0.0, h_N + b_N - b_int);
        float h_B_star = max(0.0, h_c + b_c - b_int);
        
        hll_flux(h_T_star, h_T_star * v_N, h_T_star * u_N, v_N, u_N,
                 h_B_star, h_B_star * v_c, h_B_star * u_c, v_c, u_c,
                 params.gravity, params.h_dry,
                 fN_h, fN_qz, fN_qx);
        s_bed_N = 0.5 * params.gravity * (h_c * h_c - h_B_star * h_B_star);
    } else {
        if (params.boundary_type == 0) { // WALL
            fN_h = 0.0; fN_qx = 0.0; fN_qz = 0.5 * params.gravity * h_c * h_c;
        } else { // OUTFLOW
            fN_h = qz_c; fN_qx = qx_c * v_c; fN_qz = qz_c * v_c + 0.5 * params.gravity * h_c * h_c;
        }
    }
    
    // ------------------------------------------------------------------------
    // State Integration
    // ------------------------------------------------------------------------
    float dtdx = params.dt / params.dx;
    float dtdz = params.dt / params.dz;
    
    float new_h = h_c - dtdx * (fE_h - fW_h) - dtdz * (fS_h - fN_h);
    
    // Weather terms
    new_h += params.rain_rate * params.dt;
    if (new_h > 0.0 && params.infil_rate > 0.0) {
        new_h -= min(new_h, params.infil_rate * params.dt);
    }
    if (new_h > 0.0 && params.evap_rate > 0.0) {
        new_h -= min(new_h, params.evap_rate * params.dt);
    }
    new_h = max(0.0, new_h);
    
    float new_qx = 0.0;
    float new_qz = 0.0;
    
    if (new_h > params.h_dry) {
        new_qx = qx_c - dtdx * (fE_qx - fW_qx - (s_bed_E + s_bed_W)) - dtdz * (fS_qx - fN_qx);
        new_qz = qz_c - dtdx * (fE_qz - fW_qz) - dtdz * (fS_qz - fN_qz - (s_bed_S + s_bed_N));
        
        // Semi-implicit Manning bed friction
        if (params.manning_n > 0.0) {
            float gn2 = params.gravity * params.manning_n * params.manning_n;
            float un = new_qx / new_h;
            float vn = new_qz / new_h;
            float spd = sqrt(un * un + vn * vn);
            if (spd > 1e-5) {
                float h_pow = pow(new_h, 4.0 / 3.0);
                float cf = (gn2 * spd) / max(1e-4, h_pow);
                float denom = 1.0 + params.dt * cf;
                new_qx /= denom;
                new_qz /= denom;
            }
        }
    }
    
    out_h[idx] = new_h;
    out_qx[idx] = new_qx;
    out_qz[idx] = new_qz;
}

