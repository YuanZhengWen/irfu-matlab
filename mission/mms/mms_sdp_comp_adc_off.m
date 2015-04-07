function [ ADC_off ] = mms_sdp_comp_adc_off(  )
% Compute ADC offset for each time stamp in DCE from spinfits
% based on Cluster functions @ClusterProc/getData.m and irf_waverage.m

global MMS_CONST, if isempty(MMS_CONST), MMS_CONST = mms_constants(); end

% Default output
ADC_off = MMS_CONST.Error;

% default settings
adc_off_despike = false; % disabled for test data
nPointsADCOffset = 5; %or 7 or 9 or...?;

dce = mms_sdp_datamanager('dce');
if mms_is_error(dce)
  errStr='Bad DCE input, cannot proceed.';
  irf.log('critical',errStr); error(errStr);
end
spinfits = mms_sdp_datamanager('spinfits');
if mms_is_error(spinfits)
  errStr='Bad SPINFITS input, cannot proceed.';
  irf.log('critical',errStr); error(errStr);
end

sdpProbes = fieldnames(spinfits.sfit); % default {'e12', 'e34'}

for iProbe=1:numel(sdpProbes)
  % adc_off = ["sfit timestamp", "sfit A-coeff"], where timestamp are by
  % default every 5 seconds (tt2000 int64). Convert both to "double" for
  % interp1 and similar things to work.
  adc_off = [double(spinfits.time), double(spinfits.sfit.(sdpProbes{iProbe})(:,1))];

  max_off = adc_off(~isnan(adc_off(:,2)),:);
  adc_off_mean = mean(max_off(:,2));
  max_off = 3*std(max_off(:,2));

  % Replace NaN with mean value
  adc_off(isnan(adc_off(:,2)),2) = adc_off_mean;

  if(adc_off_despike)
    % if adc_despike, locate large adc_off
    idx = find( abs(adc_off(:,2))-adc_off_mean > max_off);
    if(~isempty(idx))
      adc_off(idx,2) = 0;
      adc_off_mean = mean(abs(adc_off(:,2))>0);
      adc_off(idx,2) = adc_off_mean;
    end
  end

  % Smooth ADC offsets
  adc_off = mms_wavege(adc_off, nPointsADCOffset);
  
  if(size(adc_off,1)==1)
    % Only one good adc_offset (possibly because only one spinfit).
    ADCoff.(sdpProbes{iProbe})(1:length(dce.time),1) = adc_off(:,2);
  else
    % Resample adc offset to match up with dce timestamps
    ADCoff.(sdpProbes{iProbe}) = interp1(adc_off(:,1), adc_off(:,2), ...
      double(dce.time), 'linear', 'extrap');
  end
end

% If ADCcoff was succesfully created, return it as output
if(isstruct(ADCoff)), ADC_off = ADCoff; end

end


function [ out ] = mms_wavege(data, nPoints)
  % Weigted average function.
  narginchk(2,2); nargoutchk(1,1);

  if( ~ismember(nPoints,[5 7 9]) )
    errStr='nPoints must be 5, 7 or 9';
    irf.log('critical',errStr);  error(errStr);
  end
  if( size(data,1)<=1 )
    irf.log('warning',['Not enough points (' num2str(size(data,1)) ') to average.']);
    out = data;
    return
  end

  ndata = size(data,1);
  ncol = size(data,2);

  out = data;
  out(isnan(out)) = 0; % set NaNs to zeros

  padd = zeros(1, floor(nPoints/2)); % Calculate padding
  for col=2:ncol
    dtmp = [padd, out(:,col)', padd]; % Apply padding at begining and end
    for j=1:ndata
      out(j,col) = w_ave(dtmp(j:j+nPoints-1), nPoints);
    end
  end

  % Make sure we do return matrix of the same size
  out = out(1:ndata, :);
end

function av = w_ave(x, nPoints)
  switch nPoints
    % get weight factor m, (normalized to one).
    case 5
      % Weights based on Cluster EFW
      m = [.1 .25 .3 .25 .1];
    case 7
      % Weights bases on Cluster EFW
      m = [.07 .15 .18 .2 .18 .15 .07];
    case 9
      % Weights based on almost "Binominal" distribution, given by:
      %y=binopdf(0:10,10,0.5);y(5)=y(5)+y(1);y(1)=0;y(7)=y(7)+y(end);y(end)=0;
      %m=y(2:end-1); sum(m)==1;
      m = [0.009765625, 0.0439453125, 0.1181640625, 0.205078125, ...
        0.2470703125, 0.205078125 0.1171875 0.0439453125 0.009765625];
    otherwise
      errStr='nPoints must be 5, 7 or 9';
      irf.log('critical',errStr);      error(errStr);
  end

  cor = sum(m(x==0)); % find missing points==0
  if cor==1
    av = 0;
  else
    av = sum(x.*m)/(1-cor);
  end

end