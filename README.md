# LEO passive-radar detectability planner
MATLAB model for predicting whether satellites and other low Earth orbit (LEO)
objects can be detected by FM, DAB+ and DTV passive radar from Cooby Creek,
UQ St Lucia or any other site in South East Queensland.

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
 - leo_app.m             Interactive planner (GUI)
 - leo_detectability.m   Model entry point (all modes)
- leo_inputs.m          Defaults, workbook reading, site and receiver setup
- leo_orbits.m          TLE/SATCAT loading, RCS assignment, SGP4 states, passes
- leo_radar.m           Antenna, receiver noise, Mie RCS, bistatic S/N
- leo_search.m          Ranking, pass search, best site, altitude curves
- leo_terrain.m         Longley-Rice terrain loss
- leo_utils.m           Shared helpers
- leo_inputs.xlsx       Transmitters, RCS corrections, patterns, Assumptions
- altitude_curves.m     S/N vs altitude figures (standalone script)

## Created automatically (delete to rebuild)
leo_hardware.mat, best_site.mat, celestrak_merged.tle, mie_cache.mat,
terrain and pattern caches

## Quick start
leo_app             % interactive planner
altitude_curves     %S/N-vs-altitude figures

## References
1. K. Jdrzejewski, M. Malanowski, M. Płotka, K. Kulpa, and M. Pożoga, “Multistatic Localisation in Passive Radar System for LEO Space Objects Observation Using Terrestrial Illuminators and LOFAR Radio Telescope,” IET Radar, Sonar & Navigation, vol. 19, no. 1, Jan. 2025, issn: 1751-8784. doi: 10.1049/rsn2.70009.
2. S. J. Tingay et al., “On the detection and tracking of space debris using the murchison widefield array. I. Simulations and test observations demonstrate feasibility,” Astronomical Journal, vol. 146, no. 4, Oct. 2013, issn: 00046256. doi: 10.1088/0004-6256/146/4/103.
3. Broadcast transmitter data, 2026. [Online]. Available: https://www.acma.gov.au.
4. T. S. Kelso, CelesTrak: GP element sets and SATCAT, 2026. [Online]. Available: https://celestrak.org.
5. Aerospace Toolbox propogateOrbit, 2026. [Online]. Available: https://au.mathworks.com/help/aerotbx/ug/propagateorbit.html
6. Direct Signal Interference (DSI) Suppression In Passive Radar, 2026. [Online]. Available: https : / / au . mathworks . com / help / phased / ug / direct -signal - interference - dsi - suppression - in - passive - radar . html #DSISuppressionInPassiveRadarExample-17.
7. LongleyRice, 2026. [Online]. Available: https://au.mathworks.com/help/antenna/ref/rfprop.longleyrice.htm

## AI use declaration
Generative AI tools were used in developing this model. The author takes responsibility for critically evaluating and integrating the AI-generated content, and for ensuring it meets academic integrity standards.

AI model and date          Use                                  Explanation
Claude, 30 Apr - 5 May     Data analysis                        Coding in Python
Claude, 16 Oct - 7 Nov     Methodological support; data         Model and simulation
                           analysis                             code development
