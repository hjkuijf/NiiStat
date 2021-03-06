function nii_stat_svm(les,beh, beh_names, statname, les_names, subj_data, roifname, logicalMask, hdr)
analyzing_connectome = false;
voxelwise_analysis = isempty (les_names);

if numel(les_names) ~= size(les,2) %for connectome analyses
    les_matrix = [];
    n = 0;
    % the for loops changed by GY
    for i = 2:length(les_names)
        for j = 1:(i-1) 
            area_name = [les_names{i} '*' les_names{j}];
            n = n+1;
            les_matrix{n} = area_name; %#ok<AGROW>
        end
    end
    analyzing_connectome = true;
    nLabel = numel(les_names);
    les_names = les_matrix;    
end

% added by GY
if ~voxelwise_analysis % if ROI analysis (as opposed to voxelwise)
    les = les (:, logicalMask);
    les_names = les_names (logicalMask);
    if numel(les_names) ~= size(les,2)
        fprintf('%s error: number of feature names does not match number of features',mfilename);
        return;
    end    
else
    bb = unique (les (:));
    if length (bb) == 2 && bb(1) == 0 && bb(2) == 1 % voxelwise lesion maps
        % Normalize the lesion maps: divide each (binary) voxel by sqrt(lesion size)
        % So, each subject's lesion vector has unit norm;
        % this could help reduce the effect of lesion size.
        % See Zhang et al., "Multivariate Lesion-Symptom Mapping Using
        % Support Vector Regression", HBM 2014, section 3.5
        les = les ./ repmat (sqrt (sum (les, 2)), [1 size(les, 2)]);
        les (find (isnan (les))) = 0;
    end
end


if ~exist('statname','var')
    statname = 'anonymous';
end
if ~exist('subj_data','var')
    subj_data = [];
end;
chDirSub([statname '_svm']);
diary ([deblank(statname) 'svm.txt']);
for j = 1:size(beh_names,2) %for each beahvioral variable
    beh_name1 = beh_names{j};
    beh1 = beh(:,j);
    if ~voxelwise_analysis
        [fnm, nOK] = tabFileSub(les,beh1, beh_name1,  les_names, subj_data);
    else
        nOK = 1;
    end
    
    if nOK < 1
        fprintf('Skipping SVM/SVR: no valid data\n');
    else
        % restructured by GY
        if nii_isBinary(beh1)
            % do 100 splits for voxelwise SVM, and 500 splits for ROI SVM
            if voxelwise_analysis
                [~, loadingMap{1}, ~, p] = nii_stat_svm_core(les, beh1, 100); 
            else
                [~, loadingMap{1}, ~, p] = nii_stat_svm_core(les, beh1, 500); %do not specify thresholds: svm_core will select
                out_name{1} = [statname '_' deblank(beh_name1) '_svm'];
                reportLoadingsSub (loadingMap{1}, les_names, deblank (beh_name1), p, 1);
            end
        else
            if voxelwise_analysis
                [~, loadingMap{1}, ~, p] = nii_stat_svr_core (les, beh1, deblank (beh_name1), 0);
            else
                clipping_list = [0 1 -1];
                clipping_str = {'2tail' '1tailPOS' '1tailNEG'};
                for k = 1:length(clipping_list)
                    [~, loadingMap{k}, ~, p] = nii_stat_svr_core(les, beh1, deblank (beh_name1), clipping_list(k)); %compute regression
                    out_name{k} = [statname '_' deblank(beh_name1) '_svr_' clipping_str{k}];
                    reportLoadingsSub (loadingMap{k}, les_names, deblank (beh_name1), p, 0);
                end
            end
        end        
        if ~isempty (loadingMap{1}) % if analysis didn't work, loadingMap will be empty --GY
            if exist('roifname','var') && ~isempty(roifname)
                for k = 1:length(loadingMap) % length is either 1 for SVM and vox SVR, or 3 for ROI SVR
                    unfolded_map = zeros (length (logicalMask), 1);
                    unfolded_map (logicalMask) = loadingMap{k};
                    if ~analyzing_connectome
                        nii_array2roi (unfolded_map, roifname, [out_name{k} '_unthreshZ.nii']);
                    else
                        weight_matrix = zeros (nLabel, nLabel);
                        upper_triangle = logical (triu (ones (nLabel), 1));
                        weight_matrix (upper_triangle) = unfolded_map;
                        [~, atlas_name] = fileparts (roifname);
                        %saveNodzSub(atlas_name, weight_matrix, [out_name{k} '.nodz']);
                        nii_save_nodz(atlas_name, weight_matrix, [out_name{k} '_unthreshZ.nodz'], logicalMask);
                    end
                end % for k = 1:length(loadingMap)
            end
            if voxelwise_analysis
                out_name = [statname '_' deblank(beh_name1) '_svr'];
                save_voxelwise_loadings (loadingMap{1}, logicalMask, hdr, out_name);
            end
        end
        % /GY
    end
end
diary off %stop logging text
cd .. %leave the folder created by chDirSub
%end nii_stat_svm() LOCAL FUNCTIONS FOLLOW

function [fnm, nOK] = tabFileSub(les,beh1, beh_name1,  les_names, subj_data)  
if size(les,1) ~= size(beh1,1)
    error('nii_stat_svm confused');
end
fnm = [beh_name1  '.tab'];
fid = fopen(fnm, 'w');
n_subj = size(les,1);
fprintf(fid,'filename\t');
for j = 1:numel(les_names)
     fprintf(fid,'%s\t', les_names{j}); 
end
fprintf(fid,'%s\t', beh_name1);
fprintf(fid,'\n');
nOK = 0;
for i = 1:n_subj
    if  ~isfinite(std(les(i,:)))
        fprintf('%s WARNING: Skipping %s due to bogus data (NaN)\n', mfilename, subj_data{i}.filename);
    else
        if (std(les(i,:)) == 0) 
            fprintf('%s WARNING: No variability in imaging data for %s (all regions have an intensity of %g)\n', mfilename, subj_data{i}.filename, les(i,1));
        end
        if ~isempty('subj_data')
           fprintf(fid,'%s\t',subj_data{i}.filename); 
        else
            fprintf(fid,'%s\t',num2str(i));
        end
        for j = 1:numel(les_names)
             fprintf(fid,'%g\t',les(i, j));
        end
        fprintf(fid,'%g\t',beh1(i));
        fprintf(fid,'\n');
        nOK = nOK + 1;
    end
end
fclose(fid);
%end tabFileSub()

function chDirSub(statname)
datetime=datestr(now);
datetime=strrep(datetime,':',''); %Replace colon with underscore
datetime=strrep(datetime,'-','');%Replace minus sign with underscore
datetime=strrep(datetime,' ','_');%Replace space with underscore
newdir = [datetime statname];
mkdir(newdir);
cd(newdir);
%chDirSub()

% function saveNodzSub(roiname, matvals, nodzname) 
% if min(matvals(:)) == max(matvals(:)), fprintf(' No variability, will not create %s\n', nodzname); end;
% [kROI, kROINumbers, ROIIndex] = nii_roi_list(roiname, false);
% if ROIIndex < 1, return; end; %unable to find ROI
% str = nii_roi2mm (ROIIndex);
% fileID = fopen(nodzname,'w');
% fprintf(fileID, str);
% fprintf(fileID, '#ENDNODE\n');
% fclose(fileID);
% dlmwrite(nodzname,matvals,'delimiter','\t','-append')
% %saveNodzSub

function reportLoadingsSub (featureLoadings, les_names, beh_name, p, classification)
if p > 0.3
    fprintf ('Features are not reported because SVM/SVR accuracy is too poor\n');
    return;
end
if classification
    pos_str = 'class 0';
    neg_str = 'class 1';
else
    pos_str = 'higher score';
    neg_str = 'lower score';
end
threshZ = 1; % a rather arbitary threshold of "significance"
passed_thresh = abs(featureLoadings) > threshZ;
fprintf ('%s: %d features have weights greater than %d or less than -%d\n', beh_name, sum (passed_thresh), threshZ, threshZ);
featureLoadings = featureLoadings (passed_thresh);
les_names = les_names (passed_thresh);
[featureLoadings, sort_idx] = sort (featureLoadings, 'descend');
n_reported_pos = min (10, sum (featureLoadings > 0));
n_reported_neg = min (10, sum (featureLoadings < 0));
if n_reported_pos > 0
    if n_reported_pos == 10
        fprintf ('TOP 10 POSITIVE FEATURES (higher value -> %s):\n', pos_str);
    else
        fprintf ('POSITIVE FEATURES (higher value -> %s):\n', pos_str);
    end
    for i = 1:n_reported_pos
        fprintf ('%s (%g)\n', les_names{sort_idx(i)}, featureLoadings(i));
    end
end
if n_reported_neg > 0
    if n_reported_neg == 10
        fprintf ('TOP 10 NEGATIVE FEATURES (higher value -> %s):\n', neg_str);
    else
        fprintf ('NEGATIVE FEATURES (higher value -> %s):\n', neg_str);
    end
    for i = length(featureLoadings):-1:length(featureLoadings)-n_reported_neg+1        
        fprintf ('%s (%g)\n', les_names{sort_idx(i)}, featureLoadings(i));
    end
end
%reportLoadingsSub

function save_voxelwise_loadings (loadingMap, logicalMask, hdr, statName)
unfolded_map = zeros (hdr.dim);
unfolded_map (logicalMask) = loadingMap;
hdr.fname = [statName '.nii'];
hdr.pinfo = [1;0;0];
hdr.private.dat.scl_slope = 1;
hdr.private.dat.scl_inter = 0;
hdr.private.dat.dtype = 'FLOAT32-LE';%'INT16-LE', 'FLOAT32-LE';
hdr.dt    =[16,0]; %4= 16-bit integer; 16 =32-bit real datatype
spm_write_vol(hdr,unfolded_map);
% end save_voxelwise_loadings

