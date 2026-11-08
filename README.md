# LEO passive-radar detectability planner
# MATLAB model for predicting whether satellites and other low Earth orbit (LEO)
# objects can be detected by FM, DAB+ and DTV passive radar from Cooby Creek,
# UQ St Lucia or any other site in South East Queensland.

## MATLAB version
R2021a or later.

## Required toolboxes
Antenna Toolbox
    Receive antenna models and Longley-Rice terrain loss on the direct path
RF Toolbox
    Receive-chain noise (amplifier, cable and SDR cascade)
Satellite Communications Toolbox or Aerospace Toolbox
    SGP4 orbit propagation, satellite positions and pass times

## Internet access
- Terrain: the first calculation downloads the GMTED2010 elevation map. Results are cached afterwards.
- Orbit data: downloaded from CelesTrak and cached in celestrak_merged.tle.
  If a download fails, the cached copy is used.
- Site-map basemaps: streets, satellite and topographic need internet.
  grayterrain works offline once cached.

## Files (keep together in one folder)
leo_app.m             Interactive planner (GUI)
leo_detectability.m   Model entry point (all modes)
leo_inputs.m          Defaults, workbook reading, site and receiver setup
leo_orbits.m          TLE/SATCAT loading, RCS assignment, SGP4 states, passes
leo_radar.m           Antenna, receiver noise, Mie RCS, bistatic S/N
leo_search.m          Ranking, pass search, best site, altitude curves
leo_terrain.m         Longley-Rice terrain loss
leo_utils.m           Shared helpers
leo_inputs.xlsx       Transmitters, RCS corrections, patterns, Assumptions
altitude_curves.m     S/N vs altitude figures (standalone script)

## Created automatically (delete to rebuild)
leo_hardware.mat, best_site.mat, celestrak_merged.tle, mie_cache.mat,
terrain and pattern caches

## Quick start
leo_app             % interactive planner
altitude_curves     %S/N-vs-altitude figures
