function api = leo_terrain()
%LEO_TERRAIN  Terrain prediction: Longley-Rice direct-path loss (Antenna /
%   Communications Toolbox, gmted2010 elevation data, cached on disk) and a land check.
%   Returns handles to its functions, e.g. X = leo_terrain(); X.onLand(...).
%   Part of the LEO passive-radar planner (main file: leo_detectability.m).
    persistent A
    if isempty(A)
        A = struct( ...
            'onLand', @onLand,  ...
            'terrainExcessLoss', @terrainExcessLoss);
    end
    api = A;
end

function L = terrainExcessLoss(rx, ch, P)
% Longley-Rice path loss minus free-space loss (dB) for the direct path
% from every transmitter to the receiver.
% Speed-ups: channels at the same mast and polarisation within ~50 MHz share
% one calculation, and results are cached in memory and on disk
% (P.terrainCacheFile), independent of the hardware settings, so each path
% is only ever computed once per receiver site.
    persistent mem
    c = 299792458;  nCh = size(ch,1);  L = zeros(nCh,1);
    cacheFile = P.terrainCacheFile;
    if isempty(mem)
        mem = containers.Map();
        if ~isempty(cacheFile) && isfile(cacheFile)
            try, s = load(cacheFile, 'terrainCache'); mem = s.terrainCache; catch, end
        end
    end
    keys_ = cell(nCh,1);  hz = false(nCh,1);
    for q = 1:nCh
        if numel(ch(q,:)) >= 11, hz(q) = strcmp(ch{q,11}, 'H'); else, hz(q) = strcmp(ch{q,7}, 'DTV'); end
        keys_{q} = sprintf('%s|%.5f,%.5f|%g|%s|%.4f,%.4f,%g|%d|%d', P.terrainMap, rx.lat, rx.lon, P.rxHeight, ...
                           P.climate, ch{q,4}, ch{q,5}, ch{q,8}, hz(q), round(ch{q,2}/50));
    end
    [uk, first] = unique(keys_, 'stable');
    todo = first(~isKey(mem, uk));
    if ~isempty(todo)
        fprintf('Terrain: %d new path(s) for %s (cached afterwards)...\n', numel(todo), rx.name);
        rxs = rxsite('Name', rx.name, 'Latitude', rx.lat, 'Longitude', rx.lon, 'AntennaHeight', P.rxHeight);
        for q = todo(:).'
            f  = ch{q,2}*1e6;
            tx = txsite('Name', ch{q,6}, 'Latitude', ch{q,4}, 'Longitude', ch{q,5}, ...
                        'AntennaHeight', max(ch{q,8}, 0.5), 'TransmitterFrequency', f);
            if hz(q), pol = "horizontal"; else, pol = "vertical"; end
            pm = propagationModel("longley-rice", "Climate", P.climate, "AntennaPolarization", pol);
            pl = pathloss(pm, rxs, tx, 'Map', P.terrainMap);
            d  = distance(tx, rxs, 'euclidean');
            mem(keys_{q}) = pl - 20*log10(4*pi*d*f/c);
        end
        if ~isempty(cacheFile)
            terrainCache = mem;
            try, save(cacheFile, 'terrainCache'); catch, end
        end
    end
    for q = 1:nCh, L(q) = mem(keys_{q}); end
end

function tf = onLand(lat, lon)
% True unless the terrain data puts the point at or below sea level (water).
% (Antenna Toolbox / Communications Toolbox rxsite elevation.)
    tf = true;
    try
        tf = elevation(rxsite('Latitude', lat, 'Longitude', lon), 'Map', "gmted2010") > 0.5;
    catch
    end
end
