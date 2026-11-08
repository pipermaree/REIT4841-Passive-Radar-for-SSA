function api = leo_utils()
%LEO_UTILS  Helpers shared by the planner files: coordinates, file locations,
%   toolbox checks, channel names.
%   Returns handles to its functions, e.g. X = leo_utils(); X.chanName(...).
%   Part of the LEO passive-radar planner (main file: leo_detectability.m).
    persistent A
    if isempty(A)
        A = struct( ...
            'chanName', @chanName,  ...
            'chanNames', @chanNames,  ...
            'enuBasis', @enuBasis,  ...
            'fieldOr', @fieldOr,  ...
            'hasFcn', @hasFcn,  ...
            'modelPath', @modelPath,  ...
            'wgs84', @wgs84);
    end
    api = A;
end

function p = modelPath(f)
% A bare file name is placed in the folder that holds this model file, so caches
% are found again whatever MATLAB's current folder is. Paths are left as given.
    if isempty(fileparts(f))
        p = fullfile(fileparts(mfilename('fullpath')), f);
    else
        p = f;
    end
end

function [p, up] = wgs84(lat, lon, h)
% WGS84 ECEF position (m) and local up unit vector.
    a = 6378137;  e2 = 6.69437999014e-3;
    N = a / sqrt(1 - e2*sind(lat)^2);
    p = [(N+h)*cosd(lat)*cosd(lon), (N+h)*cosd(lat)*sind(lon), (N*(1-e2)+h)*sind(lat)];
    up = [cosd(lat)*cosd(lon), cosd(lat)*sind(lon), sind(lat)];
end

function s = chanName(row)
% Callsign (or DAB+ block) plus the area served, e.g. 'SBS33 (Darling Downs)'.
    if strcmp(row{7}, 'DR')
        blocks = [202.928 204.640 206.352 208.064];  names = {'9A','9B','9C','9D'};
        [d, i] = min(abs(blocks - row{2}));
        if d < 0.01, s = ['DAB+ ' names{i}]; else, s = 'DAB+'; end
    else
        s = row{6};
    end
    if numel(row) >= 9 && ~isempty(row{9}), s = sprintf('%s (%s)', s, row{9}); end
end

function [p, E, N, U] = enuBasis(lat, lon, Re)
% ECEF position on a spherical Earth plus local East/North/Up unit vectors.
    U = [cosd(lat)*cosd(lon), cosd(lat)*sind(lon), sind(lat)];
    E = [-sind(lon), cosd(lon), 0];
    N = cross(U, E);
    p = Re*U;
end

function nm = chanNames(ch, idx)
    nm = string(arrayfun(@(k) chanName(ch(k,:)), idx(:), 'UniformOutput', false));
end

function ok = hasFcn(name)
% True if a function or class is on the path (exist gives 2 for a file and 8 for
% a class, e.g. satelliteScenario, so test with which instead).
    ok = ~isempty(which(name));
end

function v = fieldOr(s, f, d)
    if isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
    if isstring(v), v = char(v); end
end
