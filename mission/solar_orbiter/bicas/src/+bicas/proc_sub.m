% Class that collects "processing functions" as public static methods.
%
% This class is not meant to be instantiated.
% 
% Author: Erik P G Johansson, IRF-U, Uppsala, Sweden
% First created 2017-02-10, with source code from data_manager_old.m.
%
%
% CODE CONVENTIONS
% ================
% - It is implicit that arrays/matrices representing CDF data, or "CDF-like" data, use the first MATLAB array index to
%   represent CDF records.
%
%
% DEFINITIONS, NAMING CONVENTIONS
% ===============================
% See bicas.calib.
%
%
% SOME INTERMEDIATE PROCESSING DATA FORMATS
% =========================================
% - PreDC = Pre-Demuxing-Calibration Data
%       Generic data format that can represent all forms of input datasets before demuxing and calibration. Can use an
%       arbitrary number of samples per record. Some variables are therefore not used in CWF output datasets.
%       Consists of struct with fields:
%           .Epoch
%           .ACQUISITION_TIME
%           .samplesCaTm     : 1D, size 5 cell array. {iBltsId} = NxM arrays, where M may be 1 (1 sample/record) or >1.
%           .freqHz          : Snapshot frequency in Hz. Unimportant for one sample/record data.
%           .DIFF_GAIN
%           .MUX_SET
%           QUALITY_FLAG
%           QUALITY_BITMASK
%           DELTA_PLUS_MINUS
%           % SAMP_DTIME          % Only important for SWF. - Abolished?
%       Fields are "CDF-like": rows=records, all have same number of rows.
% - PostDC = Post-Demuxing-Calibration Data
%       Like PreDC but with additional fields. Tries to capture a superset of the information that goes into any
%       dataset produced by BICAS.
%       Has extra fields:
%           .DemuxerOutput   : struct with fields.
%               dcV1, dcV2, dcV3,   dc12, dc13, dc23,   acV12, acV13, acV23.
%           .IBIAS1
%           .IBIAS2
%           .IBIAS3
%
classdef proc_sub
%#######################################################################################################################
% PROPOSAL: Split into smaller files.
%   PROPOSAL: proc_LFR
%   PROPOSAL: proc_TDS
%   PROPOSAL: proc_demux_calib
%
% PROPOSAL: Use double for all numeric zVariables in the processing. Do not produce or require proper type, e.g. integers, in any
%           intermediate processing. Only convert to the proper data type/class when writing to CDF.
%   PRO: Variables can keep NaN to represent fill/pad value, also for "integers".
%   PRO: The knowledge of the dataset CDF formats is not spread out over the code.
%       Ex: Setting default values for PreDc.QUALITY_FLAG, PreDc.QUALITY_BITMASK, PreDc.DELTA_PLUS_MINUS.
%       Ex: ACQUISITION_TIME.
%   CON: Less assertions can be made in utility functions.
%       Ex: proc_utils.ACQUISITION_TIME_*, proc_utils.tt2000_* functions.
%   CON: ROUNDING ERRORS. Can not be certain that values which are copied, are actually copied.
%   --
%   NOTE: Functions may in principle require integer math to work correctly.
% --
% PROPOSAL: Derive DIFF_GAIN (from BIAS HK using time interpolation) in one code common to both LFR & TDS.
%   PROPOSAL: Function
%   PRO: Uses flag for selecting interpolation time in one place.
% PROPOSAL: Derive HK_BIA_MODE_MUX_SET (from BIAS SCI or HK using time interpolation for HK) in one code common to both LFR & TDS.
%   PROPOSAL: Function
%   PRO: Uses flag for selecting HK/SCI DIFF_GAIN in one place.
%   PRO: Uses flag for selecting interpolation time in one place.
%--
% NOTE: Both BIAS HK and LFR SURV CWF contain MUX data (only LFR has one timestamp per snapshot). True also for other input datasets?
%
% PROPOSAL: Every processing function should use a special function for asserting and retrieving the right set of
%           InputsMap keys and values.
%   NOTE: Current convention/scheme only checks the existence of required keys, not absence of non-required keys.
%   PRO: More assertions.
%   PRO: Clearer dependencies.
%
% PROPOSAL: Assertions after every switch statement that differentiates different processing data/dataset versions.
%           Describe what they should all "converge" on, and make sure they actually do.
%
% PROPOSAL: Instantiate class, use instance methods instead of static.
%   PRO: Can have SETTINGS and constants as instance variable instead of calling global variables.
%
% PROPOSAL: Submit zVar variable attributes.
%   PRO: Can interpret fill values.
%       Ex: Can doublecheck TDS RSWF snapshot length using fill values and compare with zVar SAMPS_PER_CH (which seems to be
%       bad).
% PROPOSAL: Return (to execute_sw_mode), global attributes.
%   PRO: Needed for output datasets: CALIBRATION_TABLE, CALIBRATION_VERSION
%       ~CON: CALIBRATION_VERSION refers to algorithm and should maybe be a SETTING.
%
% PROPOSAL: Separate LFR and TDS in different files.
%
% PROPOSAL: Clean-up: Not have hasSnapshotFormat in a cell array just to avoid triggering
%   assertion (bicas.proc_utils.assert_struct_num_fields_have_same_N_rows).
%#######################################################################################################################

    methods(Static, Access=public)
        
        function HkSciTime = process_HK_to_HK_on_SCI_TIME(Sci, Hk)
        % Processing function
        
            global SETTINGS
            
            % ASSERTIONS
            EJ_library.utils.assert.struct2(Sci, {'ZVars', 'Ga'}, {})
            EJ_library.utils.assert.struct2(Hk,  {'ZVars', 'Ga'}, {})
            
            HkSciTime = [];
            
            
            
            % Define local convenience variables. AT = ACQUISITION_TIME
            ACQUISITION_TIME_EPOCH_UTC = SETTINGS.get_fv('PROCESSING.ACQUISITION_TIME_EPOCH_UTC');
            
            hkAtTt2000  = bicas.proc_utils.ACQUISITION_TIME_to_tt2000(  Hk.ZVars.ACQUISITION_TIME, ACQUISITION_TIME_EPOCH_UTC);
            sciAtTt2000 = bicas.proc_utils.ACQUISITION_TIME_to_tt2000( Sci.ZVars.ACQUISITION_TIME, ACQUISITION_TIME_EPOCH_UTC);
            hkEpoch     = Hk.ZVars.Epoch;
            sciEpoch    = Sci.ZVars.Epoch;
            
            %==================================================================
            % Log time intervals to enable comparing available SCI and HK data
            %==================================================================
            bicas.proc_utils.log_tt2000_array('HK  ACQUISITION_TIME', hkAtTt2000)
            bicas.proc_utils.log_tt2000_array('SCI ACQUISITION_TIME', sciAtTt2000)
            bicas.proc_utils.log_tt2000_array('HK  Epoch           ', hkEpoch)
            bicas.proc_utils.log_tt2000_array('SCI Epoch           ', sciEpoch)

            %=========================================================================================================
            % 1) Convert time to something linear in time that can be used for processing (not storing time to file).
            % 2) Effectively also chooses which time to use for the purpose of processing:
            %       (a) ACQUISITION_TIME, or
            %       (b) Epoch.
            %=========================================================================================================
            if SETTINGS.get_fv('PROCESSING.USE_AQUISITION_TIME_FOR_HK_TIME_INTERPOLATION')
                bicas.log('info', 'Using HK & SCI zVariable ACQUISITION_TIME (not Epoch) for interpolating HK dataset data to SCI dataset time.')
                hkInterpolationTimeTt2000  = hkAtTt2000;
                sciInterpolationTimeTt2000 = sciAtTt2000;
            else
                bicas.log('info', 'Using HK & SCI zVariable Epoch (not ACQUISITION_TIME) for interpolating HK dataset data to SCI dataset time.')
                hkInterpolationTimeTt2000  = hkEpoch;
                sciInterpolationTimeTt2000 = sciEpoch;
            end
            clear hkAtTt2000 sciAtTt2000
            clear hkEpoch    sciEpoch



            %=========================================================================================================
            % Derive MUX_SET
            % --------------
            % NOTE: Only obtains one MUX_SET per record ==> Can not change MUX_SET in the middle of a record.
            % NOTE: Can potentially obtain MUX_SET from LFR SCI.
            %=========================================================================================================            
            HkSciTime.MUX_SET = bicas.proc_utils.nearest_interpolate_float_records(...
                double(Hk.ZVars.HK_BIA_MODE_MUX_SET), ...
                hkInterpolationTimeTt2000, ...
                sciInterpolationTimeTt2000);   % Use BIAS HK.
            %PreDc.MUX_SET = LFR_cdf.BIAS_MODE_MUX_SET;    % Use LFR SCI. NOTE: Only possible for ___LFR___.



            %=========================================================================================================
            % Derive DIFF_GAIN
            % ----------------
            % NOTE: Not perfect handling of time when 1 snapshot/record, since one should ideally use time stamps
            % for every LFR _sample_.
            %=========================================================================================================
            HkSciTime.DIFF_GAIN = bicas.proc_utils.nearest_interpolate_float_records(...
                double(Hk.ZVars.HK_BIA_DIFF_GAIN), hkInterpolationTimeTt2000, sciInterpolationTimeTt2000);



            % ASSERTIONS
            EJ_library.utils.assert.struct2(HkSciTime, {'MUX_SET', 'DIFF_GAIN'}, {})
        end



        function [PreDc, calibFunc] = process_LFR_to_PreDC(Sci, inputSciDsi, HkSciTime, Cal)
        % Processing function. Convert LFR CDF data to PreDC.
        %
        % Keeps number of samples/record. Treats 1 samples/record "length-one snapshots".
        
        % PROBLEM: Hardcoded CDF data types (MATLAB classes).
        % MINOR PROBLEM: Still does not handle LFR zVar TYPE for determining "virtual snapshot" length.
        % Should only be relevant for V01_ROC-SGSE_L2R_RPW-LFR-SURV-CWF (not V02) which should expire.
        
            LFR_SWF_SNAPSHOT_LENGTH = 2048;
        
            % ASSERTIONS
            EJ_library.utils.assert.struct2(Sci,       {'ZVars', 'Ga'}, {})
            EJ_library.utils.assert.struct2(HkSciTime, {'MUX_SET', 'DIFF_GAIN'}, {})
            
            nRecords = size(Sci.ZVars.Epoch, 1);            
            C = bicas.proc_utils.classify_DATASET_ID(inputSciDsi);
           
            V = Sci.ZVars.V;
            E = permute(Sci.ZVars.E, [1,3,2]);
            % Switch last two indices of E.
            % ==> index 2 = "snapshot" sample index, including for CWF (sample/record, "snapshots" consisting of 1 sample).
            %     index 3 = E1/E2 component
            %               NOTE: 1/2=index into array; these are diffs but not equivalent to any particular diffs).
            
            nSamplesPerRecord = size(V, 2);
            
            % ASSERTIONS
            if C.isLfrSwf
                assert(nSamplesPerRecord == LFR_SWF_SNAPSHOT_LENGTH)
            else
                assert(nSamplesPerRecord == 1)
            end
            assert(size(E, 3) == 2)



            if     C.isLfrSbm1
                FREQ = ones(nRecords, 1) * 1;   % Always value "1" (F1).
            elseif C.isLfrSbm2
                FREQ = ones(nRecords, 1) * 2;   % Always value "2" (F2).
            else
                FREQ = Sci.ZVars.FREQ;
            end
            assert(size(FREQ, 2) == 1)
            
            
            
            freqHz = bicas.proc_utils.get_LFR_frequency( FREQ );   % NOTE: Needed also for 1 SPR.

            % Obtain the relevant values (one per record) from zVariables R0, R1, R2, and the virtual "R3".
            Rx = bicas.proc_utils.get_LFR_Rx( ...
                Sci.ZVars.R0, ...
                Sci.ZVars.R1, ...
                Sci.ZVars.R2, ...
                FREQ );   % NOTE: Function also handles the imaginary zVar "R3".

            PreDc = [];
            PreDc.Epoch                  = Sci.ZVars.Epoch;
            PreDc.ACQUISITION_TIME       = Sci.ZVars.ACQUISITION_TIME;
            PreDc.DELTA_PLUS_MINUS       = bicas.proc_utils.derive_DELTA_PLUS_MINUS(freqHz, nSamplesPerRecord);            
            PreDc.freqHz                 = freqHz;
            PreDc.nValidSamplesPerRecord = ones(nRecords, 1) * nSamplesPerRecord;
            PreDc.SYNCHRO_FLAG           = Sci.ZVars.TIME_SYNCHRO_FLAG;   % NOTE: Different zVar name in input and output datasets.

            
            
            %===========================================================================================================
            % Replace illegally empty data with fill values/NaN
            % -------------------------------------------------
            % IMPLEMENTATION NOTE: QUALITY_FLAG, QUALITY_BITMASK have been found empty in test data, but should have
            % attribute DEPEND_0 = "Epoch" ==> Should have same number of records as Epoch.
            % Can not save CDF with zVar with zero records (crashes when reading CDF). ==> Better create empty records.
            % Test data: MYSTERIOUS_SIGNAL_1_2016-04-15_Run2__7729147__CNES/ROC-SGSE_L2R_RPW-LFR-SURV-SWF_7729147_CNE_V01.cdf
            %
            % PROPOSAL: Move to the code that reads CDF datasets instead. Generalize to many zVariables.
            %===========================================================================================================
            PreDc.QUALITY_FLAG    = Sci.ZVars.QUALITY_FLAG;
            PreDc.QUALITY_BITMASK = Sci.ZVars.QUALITY_BITMASK;
            if isempty(PreDc.QUALITY_FLAG)
                bicas.log('warning', 'QUALITY_FLAG from the LFR SCI source dataset is empty. Filling with empty values.')
                PreDc.QUALITY_FLAG = bicas.proc_utils.create_NaN_array([nRecords, 1]);
            end
            if isempty(PreDc.QUALITY_BITMASK)
                bicas.log('warning', 'QUALITY_BITMASK from the LFR SCI source dataset is empty. Filling with empty values.')
                PreDc.QUALITY_BITMASK = bicas.proc_utils.create_NaN_array([nRecords, 1]);
            end
            
            % ASSERTIONS
            % LFR QUALITY_FLAG, QUALITY_BITMASK not set yet (2019-09-17), but I presume they should have just one value
            % per record. BIAS output datasets should.
            assert(size(PreDc.QUALITY_FLAG,    2) == 1)
            assert(size(PreDc.QUALITY_BITMASK, 2) == 1)



            % E must be floating-point so that values can be set to NaN.
            % bicas.proc_utils.filter_rows requires this. Variable may be integer if integer in source CDF.
            E = single(E);

            PreDc.samplesCaTm    = {};
            PreDc.samplesCaTm{1} = V;
            PreDc.samplesCaTm{2} = bicas.proc_utils.filter_rows( E(:,:,1), Rx==1 );
            PreDc.samplesCaTm{3} = bicas.proc_utils.filter_rows( E(:,:,2), Rx==1 );
            PreDc.samplesCaTm{4} = bicas.proc_utils.filter_rows( E(:,:,1), Rx==0 );
            PreDc.samplesCaTm{5} = bicas.proc_utils.filter_rows( E(:,:,2), Rx==0 );

            PreDc.MUX_SET           = HkSciTime.MUX_SET;
            PreDc.DIFF_GAIN         = HkSciTime.DIFF_GAIN;
            PreDc.hasSnapshotFormat = {C.isLfrSwf};



            % NOTE: Uses iRecord to set iLsf.
            iLsfVec = FREQ + 1;   % NOTE: Translates from FREQ values (0=F0 etc) and LSF index values (1=F0) used in loaded RCT data structs.
            calibFunc = @(        dtSec, lfrSamplesTm, iBlts, BltsSrc, biasHighGain, iCalibTimeL, iCalibTimeH, iRecord) ...
                Cal.calibrate_LFR(dtSec, lfrSamplesTm, iBlts, BltsSrc, biasHighGain, iCalibTimeL, iCalibTimeH, iLsfVec(iRecord));



            % ASSERTIONS
            bicas.proc_sub.assert_PreDC(PreDc)
        end
        
        
        
        function [PreDc, calibFunc] = process_TDS_to_PreDC(Sci, inputSciDsi, HkSciTime, Cal)
        % Processing function. Convert TDS CDF data (PDs) to PreDC.
        %
        % Keeps number of samples/record. Treats 1 samples/record "length-one snapshots".
        %
        % BUG?: Does not use CHANNEL_STATUS_INFO.
        % NOTE: BIAS output datasets do not have a variable for the length of snapshots. Need to use NaN/fill value.

            % ASSERTIONS
            EJ_library.utils.assert.struct2(Sci,        {'ZVars', 'Ga'}, {})
            EJ_library.utils.assert.struct2(HkSciTime,  {'MUX_SET', 'DIFF_GAIN'}, {})
            
            C = bicas.proc_utils.classify_DATASET_ID(inputSciDsi);
            
            nRecords                  = size(Sci.ZVars.Epoch, 1);
            nVariableSamplesPerRecord = size(Sci.ZVars.WAVEFORM_DATA, 3);    % Number of samples in the variable, not necessarily actual data.
            
            freqHz = double(Sci.ZVars.SAMPLING_RATE);
            
            PreDc = [];
            
            PreDc.Epoch            = Sci.ZVars.Epoch;
            PreDc.ACQUISITION_TIME = Sci.ZVars.ACQUISITION_TIME;
            PreDc.DELTA_PLUS_MINUS = bicas.proc_utils.derive_DELTA_PLUS_MINUS(freqHz, nVariableSamplesPerRecord);
            PreDc.freqHz           = freqHz;
            if C.isTdsRswf
                
                %====================================================================================================
                % ASSERTION WARNING: Check zVar SAMPS_PER_CH for invalid values
                %
                % NOTE: Has observed invalid SAMPS_PER_CH value 16562 in
                % ROC-SGSE_L1R_RPW-TDS-LFM-RSWF-E_73525cd_CNE_V03.CDF.
                % 2019-09-18, David Pisa: Not a flaw in TDS RCS but in the source L1 dataset.
                %====================================================================================================
                SAMPS_PER_CH_MIN_VALID = 2^10;
                SAMPS_PER_CH_MAX_VALID = 2^15;
                SAMPS_PER_CH         = double(Sci.ZVars.SAMPS_PER_CH);
                SAMPS_PER_CH_rounded = round(2.^round(log2(SAMPS_PER_CH)));
                SAMPS_PER_CH_rounded(SAMPS_PER_CH_rounded < SAMPS_PER_CH_MIN_VALID) = SAMPS_PER_CH_MIN_VALID;
                SAMPS_PER_CH_rounded(SAMPS_PER_CH_rounded > SAMPS_PER_CH_MAX_VALID) = SAMPS_PER_CH_MAX_VALID;
                if any(SAMPS_PER_CH_rounded ~= SAMPS_PER_CH)
                    SAMPS_PER_CH_badValues = unique(SAMPS_PER_CH(SAMPS_PER_CH_rounded ~= SAMPS_PER_CH));
                    badValuesDisplayStr = strjoin(arrayfun(@(n) sprintf('%i', n), SAMPS_PER_CH_badValues, 'uni', false), ', ');                    
                    bicas.logf('warning', 'TDS LFM RSWF zVar SAMPS_PER_CH contains unexpected value(s), not 2^n: %s', badValuesDisplayStr)
                    
                    % NOTE: Unclear if this is the appropriate action.
                    %bicas.log('warning', 'Replacing TDS RSWF zVar SAMPS_PER_CH values with values, rounded to valid values.')
                    %SAMPS_PER_CH = SAMPS_PER_CH_rounded;
                end
                
                % NOTE: This might only be appropriate for TDS's "COMMON_MODE" mode. TDS also has a "FULL_BAND" mode
                % with 2^18=262144 samples per snapshot. You should never encounter FULL_BAND in any dataset (even on
                % ground), only used for calibration and testing. /David Pisa & Jan Soucek in emails, 2016.
                % --
                % FULL_BAND mode has each snapshot divided into 2^15 samples/record * 8 records.  /Unknown source
                % Unclear what value SAMPS_PER_CH should have for FULL_BAND mode. How does Epoch work for FULL_BAND
                % snapshots?
                PreDc.nValidSamplesPerRecord = SAMPS_PER_CH;
                
            else
                PreDc.nValidSamplesPerRecord = ones(nRecords, 1) * 1;
            end

            PreDc.QUALITY_FLAG    = Sci.ZVars.QUALITY_FLAG;
            PreDc.QUALITY_BITMASK = Sci.ZVars.QUALITY_BITMASK;
            PreDc.SYNCHRO_FLAG    = Sci.ZVars.TIME_SYNCHRO_FLAG;   % NOTE: Different zVar name in input and output datasets.
            
            modif_WAVEFORM_DATA = double(permute(Sci.ZVars.WAVEFORM_DATA, [1,3,2]));
            
            PreDc.samplesCaTm    = {};
            PreDc.samplesCaTm{1} = bicas.proc_utils.set_NaN_after_snapshots_end( modif_WAVEFORM_DATA(:,:,1), PreDc.nValidSamplesPerRecord );
            PreDc.samplesCaTm{2} = bicas.proc_utils.set_NaN_after_snapshots_end( modif_WAVEFORM_DATA(:,:,2), PreDc.nValidSamplesPerRecord );
            PreDc.samplesCaTm{3} = bicas.proc_utils.set_NaN_after_snapshots_end( modif_WAVEFORM_DATA(:,:,3), PreDc.nValidSamplesPerRecord );
            PreDc.samplesCaTm{4} = bicas.proc_utils.create_NaN_array([nRecords, nVariableSamplesPerRecord]);
            PreDc.samplesCaTm{5} = bicas.proc_utils.create_NaN_array([nRecords, nVariableSamplesPerRecord]);
            
            PreDc.MUX_SET   = HkSciTime.MUX_SET;
            PreDc.DIFF_GAIN = HkSciTime.DIFF_GAIN;
            PreDc.hasSnapshotFormat = {C.isTdsRswf};
            
            
            
            if C.isTdsCwf
                calibFunc = @(             dtSec, tdsCwfSamplesTm, iBlts, BltsSrc, biasHighGain, iCalibTimeL, iCalibTimeH, iRecord) ...
                    (Cal.calibrate_TDS_CWF(dtSec, tdsCwfSamplesTm, iBlts, BltsSrc, biasHighGain, iCalibTimeL, iCalibTimeH));
                % NOTE: Ignoring iRecord.
            elseif C.isTdsRswf
                calibFunc = @(              dtSec, tdsRswfSamplesTm, iBlts, BltsSrc, biasHighGain, iCalibTimeL, iCalibTimeH, iRecord) ...
                    (Cal.calibrate_TDS_RSWF(dtSec, tdsRswfSamplesTm, iBlts, BltsSrc, biasHighGain, iCalibTimeL, iCalibTimeH));
                % NOTE: Ignoring iRecord.
            end
            
            
            
            % ASSERTIONS
            bicas.proc_sub.assert_PreDC(PreDc)
        end



        function assert_PreDC(PreDc)
            EJ_library.utils.assert.struct2(PreDc, {...
                'Epoch', 'ACQUISITION_TIME', 'samplesCaTm', 'freqHz', 'nValidSamplesPerRecord', 'DIFF_GAIN', 'MUX_SET', 'QUALITY_FLAG', ...
                'QUALITY_BITMASK', 'DELTA_PLUS_MINUS', 'SYNCHRO_FLAG', 'hasSnapshotFormat'}, {});
            bicas.proc_utils.assert_struct_num_fields_have_same_N_rows(PreDc);
            %bicas.proc_utils.assert_struct_num_fields_have_same_N_rows(PreDc.samplesCaTm);
            
            assert(isa(PreDc.freqHz, 'double'))
        end
        
        
        
        function assert_PostDC(PostDc)
            EJ_library.utils.assert.struct2(PostDc, {...
                'Epoch', 'ACQUISITION_TIME', 'samplesCaTm', 'freqHz', 'nValidSamplesPerRecord', 'DIFF_GAIN', 'MUX_SET', 'QUALITY_FLAG', ...
                'QUALITY_BITMASK', 'DELTA_PLUS_MINUS', 'SYNCHRO_FLAG', 'DemuxerOutput', 'IBIAS1', 'IBIAS2', 'IBIAS3', 'hasSnapshotFormat'}, {});
            bicas.proc_utils.assert_struct_num_fields_have_same_N_rows(PostDc);
            %bicas.proc_utils.assert_struct_num_fields_have_same_N_rows(PostDc.samplesCaTm);
        end
        

        
        function [OutSciZVars] = process_PostDC_to_LFR(SciPostDc, outputDsi, outputVersion)
        % Processing function. Convert PostDC to any one of several similar LFR dataset PDs.
        
            % ASSERTIONS
            bicas.proc_sub.assert_PostDC(SciPostDc)
            
            OutSciZVars = [];
            
            nSamplesPerRecord = size(SciPostDc.DemuxerOutput.dcV1, 2);   % Samples per record.
            
            outputDvid = bicas.construct_DVID(outputDsi, outputVersion);
            ZVAR_FN_LIST = {'IBIAS1', 'IBIAS2', 'IBIAS3', 'V', 'E', 'EAC', 'Epoch', ...
                'QUALITY_BITMASK', 'QUALITY_FLAG', 'DELTA_PLUS_MINUS', 'ACQUISITION_TIME'};
            
            OutSciZVars.Epoch = SciPostDc.Epoch;
            OutSciZVars.ACQUISITION_TIME = SciPostDc.ACQUISITION_TIME;
            OutSciZVars.QUALITY_BITMASK  = SciPostDc.QUALITY_BITMASK;
            OutSciZVars.QUALITY_FLAG     = SciPostDc.QUALITY_FLAG;
            OutSciZVars.DELTA_PLUS_MINUS = SciPostDc.DELTA_PLUS_MINUS;
            
            % NOTE: The two cases are different in the indexes they use for OutSciZVars.
            switch(outputDvid)
                case  {'V05_SOLO_L2_RPW-LFR-SURV-CWF-E' ...
                       'V05_SOLO_L2_RPW-LFR-SBM1-CWF-E' ...
                       'V05_SOLO_L2_RPW-LFR-SBM2-CWF-E'}
                    % 'V05_ROC-SGSE_L2S_RPW-LFR-SBM1-CWF-E' ...
                    % 'V05_ROC-SGSE_L2S_RPW-LFR-SBM2-CWF-E' ...
                    % 'V05_ROC-SGSE_L2S_RPW-LFR-SURV-CWF-E' ...

                    % ASSERTION
                    assert(nSamplesPerRecord == 1, 'BICAS:proc_sub:Assertion:IllegalArgument', 'Number of samples per CDF record is not 1, as expected. Bad input CDF?')
                    assert(size(OutSciZVars.QUALITY_FLAG,    2) == 1)
                    assert(size(OutSciZVars.QUALITY_BITMASK, 2) == 1)

                    OutSciZVars.IBIAS1 = SciPostDc.IBIAS1;
                    OutSciZVars.IBIAS2 = SciPostDc.IBIAS2;
                    OutSciZVars.IBIAS3 = SciPostDc.IBIAS3;
                    assert(size(OutSciZVars.IBIAS1, 2) == 1)
                    assert(size(OutSciZVars.IBIAS2, 2) == 1)
                    assert(size(OutSciZVars.IBIAS3, 2) == 1)
                    
                    OutSciZVars.V(:,1)           = SciPostDc.DemuxerOutput.dcV1;
                    OutSciZVars.V(:,2)           = SciPostDc.DemuxerOutput.dcV2;
                    OutSciZVars.V(:,3)           = SciPostDc.DemuxerOutput.dcV3;
                    OutSciZVars.E(:,1)           = SciPostDc.DemuxerOutput.dcV12;
                    OutSciZVars.E(:,2)           = SciPostDc.DemuxerOutput.dcV13;
                    OutSciZVars.E(:,3)           = SciPostDc.DemuxerOutput.dcV23;
                    OutSciZVars.EAC(:,1)         = SciPostDc.DemuxerOutput.acV12;
                    OutSciZVars.EAC(:,2)         = SciPostDc.DemuxerOutput.acV13;
                    OutSciZVars.EAC(:,3)         = SciPostDc.DemuxerOutput.acV23;
                    
                case  {'V05_SOLO_L2_RPW-LFR-SURV-SWF-E'}
                    % 'V05_ROC-SGSE_L2S_RPW-LFR-SURV-SWF-E'
                    
                    % ASSERTION
                    assert(nSamplesPerRecord == 2048, 'BICAS:proc_sub:Assertion:IllegalArgument', 'Number of samples per CDF record is not 2048, as expected. Bad Input CDF?')
                    
                    OutSciZVars.IBIAS1           = SciPostDc.IBIAS1;
                    OutSciZVars.IBIAS2           = SciPostDc.IBIAS2;
                    OutSciZVars.IBIAS3           = SciPostDc.IBIAS3;
                    OutSciZVars.V(:,:,1)         = SciPostDc.DemuxerOutput.dcV1;
                    OutSciZVars.V(:,:,2)         = SciPostDc.DemuxerOutput.dcV2;
                    OutSciZVars.V(:,:,3)         = SciPostDc.DemuxerOutput.dcV3;
                    OutSciZVars.E(:,:,1)         = SciPostDc.DemuxerOutput.dcV12;
                    OutSciZVars.E(:,:,2)         = SciPostDc.DemuxerOutput.dcV13;
                    OutSciZVars.E(:,:,3)         = SciPostDc.DemuxerOutput.dcV23;
                    OutSciZVars.EAC(:,:,1)       = SciPostDc.DemuxerOutput.acV12;
                    OutSciZVars.EAC(:,:,2)       = SciPostDc.DemuxerOutput.acV13;
                    OutSciZVars.EAC(:,:,3)       = SciPostDc.DemuxerOutput.acV23;

                    % Only in LFR SWF (not CWF): F_SAMPLE, SAMP_DTIME
                    OutSciZVars.F_SAMPLE         = SciPostDc.freqHz;
                    ZVAR_FN_LIST{end+1} = 'F_SAMPLE';
                    
                otherwise
                    error('BICAS:proc_sub:Assertion:IllegalArgument', 'Function can not produce outputDvid=%s.', outputDvid)
            end



            OutSciZVars.SYNCHRO_FLAG = SciPostDc.SYNCHRO_FLAG;
            ZVAR_FN_LIST{end+1} = 'SYNCHRO_FLAG';
            
            
            
            % ASSERTION
            bicas.proc_utils.assert_struct_num_fields_have_same_N_rows(OutSciZVars);
            EJ_library.utils.assert.struct2(OutSciZVars, ZVAR_FN_LIST, {})
        end   % process_PostDC_to_LFR



        function OutSciZVars = process_PostDC_to_TDS(SciPostDc, outputDsi, outputVersion)
            
            % ASSERTIONS
            bicas.proc_sub.assert_PostDC(SciPostDc)
            
            OutSciZVars = [];
            
            outputDvid = bicas.construct_DVID(outputDsi, outputVersion);
            ZVAR_FN_LIST = {'IBIAS1', 'IBIAS2', 'IBIAS3', 'V', 'E', 'EAC', 'Epoch', ...
                'QUALITY_BITMASK', 'QUALITY_FLAG', 'DELTA_PLUS_MINUS', 'ACQUISITION_TIME'};

            % NOTE: The two cases are actually different in the indexes they use for OutSciZVars.
            switch(outputDvid)
                
                case {'V05_SOLO_L2_RPW-TDS-LFM-CWF-E'}
                    OutSciZVars.V(:,1)     = SciPostDc.DemuxerOutput.dcV1;
                    OutSciZVars.V(:,2)     = SciPostDc.DemuxerOutput.dcV2;
                    OutSciZVars.V(:,3)     = SciPostDc.DemuxerOutput.dcV3;
                    OutSciZVars.E(:,1)     = SciPostDc.DemuxerOutput.dcV12;
                    OutSciZVars.E(:,2)     = SciPostDc.DemuxerOutput.dcV13;
                    OutSciZVars.E(:,3)     = SciPostDc.DemuxerOutput.dcV23;
                    OutSciZVars.EAC(:,1)   = SciPostDc.DemuxerOutput.acV12;
                    OutSciZVars.EAC(:,2)   = SciPostDc.DemuxerOutput.acV13;
                    OutSciZVars.EAC(:,3)   = SciPostDc.DemuxerOutput.acV23;
                    
                case {'V05_SOLO_L2_RPW-TDS-LFM-RSWF-E'}
                    OutSciZVars.V(:,:,1)   = SciPostDc.DemuxerOutput.dcV1;
                    OutSciZVars.V(:,:,2)   = SciPostDc.DemuxerOutput.dcV2;
                    OutSciZVars.V(:,:,3)   = SciPostDc.DemuxerOutput.dcV3;
                    OutSciZVars.E(:,:,1)   = SciPostDc.DemuxerOutput.dcV12;
                    OutSciZVars.E(:,:,2)   = SciPostDc.DemuxerOutput.dcV13;
                    OutSciZVars.E(:,:,3)   = SciPostDc.DemuxerOutput.dcV23;
                    OutSciZVars.EAC(:,:,1) = SciPostDc.DemuxerOutput.acV12;
                    OutSciZVars.EAC(:,:,2) = SciPostDc.DemuxerOutput.acV13;
                    OutSciZVars.EAC(:,:,3) = SciPostDc.DemuxerOutput.acV23;
                    
                    OutSciZVars.F_SAMPLE = SciPostDc.freqHz;
                    ZVAR_FN_LIST{end+1}  = 'F_SAMPLE';
                    
                otherwise
                    error('BICAS:proc_sub:Assertion:IllegalArgument', 'Function can not produce outputDvid=%s.', outputDvid)
            end

            OutSciZVars.Epoch = SciPostDc.Epoch;
            OutSciZVars.ACQUISITION_TIME = SciPostDc.ACQUISITION_TIME;
            OutSciZVars.QUALITY_FLAG     = SciPostDc.QUALITY_FLAG;
            OutSciZVars.QUALITY_BITMASK  = SciPostDc.QUALITY_BITMASK;
            OutSciZVars.DELTA_PLUS_MINUS = SciPostDc.DELTA_PLUS_MINUS;
            OutSciZVars.IBIAS1           = SciPostDc.IBIAS1;
            OutSciZVars.IBIAS2           = SciPostDc.IBIAS2;
            OutSciZVars.IBIAS3           = SciPostDc.IBIAS3;

%             switch(outputDvid)
%                 case  {'V05_ROC-SGSE_L2S_RPW-TDS-LFM-CWF-E' ...
%                        'V05_ROC-SGSE_L2S_RPW-TDS-LFM-RSWF-E'}
%                     OutSciZVars.SYNCHRO_FLAG = SciPostDc.SYNCHRO_FLAG;
%                     ZVAR_FN_LIST{end+1} = 'SYNCHRO_FLAG';
%
%                 case  {'V05_SOLO_L2_RPW-TDS-LFM-CWF-E' ...
%                        'V05_SOLO_L2_RPW-TDS-LFM-RSWF-E'}
%                     OutSciZVars.SYNCHRO_FLAG = SciPostDc.SYNCHRO_FLAG;
%                     ZVAR_FN_LIST{end+1} = 'SYNCHRO_FLAG';
%
%                 otherwise
%                     error('BICAS:proc_sub:Assertion:IllegalArgument', 'Function can not produce outputDvid=%s.', outputDvid)
%             end
            OutSciZVars.SYNCHRO_FLAG = SciPostDc.SYNCHRO_FLAG;
            ZVAR_FN_LIST{end+1} = 'SYNCHRO_FLAG';

            % ASSERTION
            bicas.proc_utils.assert_struct_num_fields_have_same_N_rows(OutSciZVars);
            EJ_library.utils.assert.struct2(OutSciZVars, ZVAR_FN_LIST, {})
        end
        
        

        % Processing function. Converts PreDC to PostDC, i.e. demux and calibrate data.
        % Function is in large part a wrapper around "simple_demultiplex".
        %
        % NOTE: Public function as opposed to the other demuxing/calibration functions.
        %
        function PostDc = process_demuxing_calibration(PreDc, Cal, calibFunc)
        % PROPOSAL: Move the setting of IBIASx (bias current) somewhere else?
        %   PRO: Unrelated to demultiplexing.
        %   CON: Related to calibration.
        % PROPOSAL: Change name. Will not calibrate measured samples here, only currents, maybe.

            % ASSERTION
            bicas.proc_sub.assert_PreDC(PreDc);

            %=======
            % DEMUX
            %=======
            PostDc = PreDc;    % Copy all values, to later overwrite a subset of them.
            PostDc.DemuxerOutput = bicas.proc_sub.simple_demultiplex(...
                PreDc.hasSnapshotFormat{1}, ...
                PreDc.Epoch, ...
                PreDc.nValidSamplesPerRecord, ...
                PreDc.samplesCaTm, ...
                PreDc.MUX_SET, ...
                PreDc.DIFF_GAIN, ...
                PreDc.freqHz, ...
                Cal, ...
                calibFunc);

            %================================
            % Set (calibrated) bias currents
            %================================
            % BUG / TEMP: Set default values since the real bias current values are not available.
            PostDc.IBIAS1 = bicas.proc_utils.create_NaN_array(size(PostDc.DemuxerOutput.dcV1));
            PostDc.IBIAS2 = bicas.proc_utils.create_NaN_array(size(PostDc.DemuxerOutput.dcV2));
            PostDc.IBIAS3 = bicas.proc_utils.create_NaN_array(size(PostDc.DemuxerOutput.dcV3));
            
            % ASSERTION
            bicas.proc_sub.assert_PostDC(PostDc)
        end
        
    end   % methods(Static, Access=public)
            
    %###################################################################################################################
    
    methods(Static, Access=private)
    %methods(Static, Access=public)
        
        % Wrapper around "simple_demultiplex_subsequence_OLD" to be able to handle multiple CDF records with changing
        % settings (mux_set, diff_gain).
        %
        % NOTE: NOT a processing function (does not derive a PDV).
        %
        %
        % ARGUMENTS AND RETURN VALUE
        % ==========================
        % BltsSamplesTm : Size 5 cell array with numeric arrays(?). {iBlts} = samples for the corresponding BLTS.
        % MUX_SET       : Column vector. Numbers identifying the MUX/DEMUX mode. 
        % DIFF_GAIN     : Column vector. Gains for differential measurements. 0 = Low gain, 1 = High gain.
        %
        %
        % NOTE: Can handle arrays of any size as long as the sizes are consistent.
        function AsrSamplesAVolt = simple_demultiplex(hasSnapshotFormat, Epoch, nValidSamplesPerRecord, samplesCaTm, MUX_SET, DIFF_GAIN, freqHz, Cal, calibFunc)
        % PROPOSAL: Incorporate into processing function process_demuxing_calibration.
        % PROPOSAL: Assert same nbr of "records" for MUX_SET, DIFF_GAIN as for BIAS_x.
        %
        % PROPOSAL: Sequence of constant settings includes dt (for CWF)
        %   PROBLEM: Not clear how to implement it since it is a property of two records, not one.
        %       PROPOSAL: Use other utility function(s).
        %           PROPOSAL: Function that finds changes in dt.
        %           PROPOSAL: Function that further splits list of index intervals ~on the form iFirstList, iLastList.
        %           PROPOSAL: Write functions such that one can detect suspicious jumps in dt (under some threshold).
        %               PROPOSAL: Different policies/behaviours:
        %                   PROPOSAL: Assertion on expected constant dt.
        %                   PROPOSAL: Always split sequence at dt jumps.
        %                   PROPOSAL: Never  split sequence at dt jumps.
        %                   PROPOSAL: Have threshold on dt when expected constant dt.
        %                       PROPOSAL: Below dt jump threshold, never split sequence
        %                       PROPOSAL: Above dt jump threshold, split sequence
        %                       PROPOSAL: Above dt jump threshold, assert never/give error
        %
        % PROPOSAL: Sequence of constant settings includes constant NaN/non-NaN for CWF.
        %
        % PROPOSAL: Integrate into bicas.demultiplexer (as method).
        % PROPOSAL: Ignore (set NaN) for too short subsequences (CWF).
        % NOTE: Calibration is really separate from the demultiplexer. Demultiplexer only needs to split into
        % subsequences based on mux mode and latching relay, nothing else.
        %   PROPOSAL: Separate out demultiplexer. Do not call from this function.
        %
        % PROPOSAL: Function for dtSec.
        %     PROPOSAL: Some kind of assertion (assumption of) constant sampling frequency.
        %
        % PROPOSAL: Move the different conversion of CWF/SWF (one/many cell arrays) into the calibration function?!!

            global SETTINGS

            % ASSERTIONS
            assert(isscalar(hasSnapshotFormat))
            assert(iscell(samplesCaTm))
            EJ_library.utils.assert.vector(samplesCaTm)
            assert(numel(samplesCaTm) == 5)
            bicas.proc_utils.assert_cell_array_comps_have_same_N_rows(samplesCaTm)
            EJ_library.utils.assert.all_equal([...
                size(MUX_SET,             1), ...
                size(DIFF_GAIN,           1), ...
                size(samplesCaTm{1}, 1)])



            % Create empty structure to which new array components can be added.
            % NOTE: Unit is AVolt. Not including in the field name to keep them short.
            AsrSamplesAVolt = struct(...
                'dcV1',  [], 'dcV2',  [], 'dcV3',  [], ...
                'dcV12', [], 'dcV23', [], 'dcV13', [], ...
                'acV12', [], 'acV23', [], 'acV13', []);



            disableCalibration = SETTINGS.get_fv('PROCESSING.CALIBRATION.DISABLE_CALIBRATION');
            if disableCalibration
                bicas.log('warning', 'CALIBRATION HAS BEEN DISABLED via setting PROCESSING.CALIBRATION.DISABLE_CALIBRATION.')
            end
            
            dlrUsing12 = bicas.demultiplexer_latching_relay(Epoch);
            iCalibL    = Cal.get_calibration_time_L(Epoch);
            iCalibH    = Cal.get_calibration_time_H(Epoch);



            %======================================================================
            % (1) Find continuous subsequences of records with identical settings.
            % (2) Process data separately for each such sequence.
            %======================================================================
            [iEdgeList]             = bicas.proc_utils.find_constant_sequences(MUX_SET, DIFF_GAIN, dlrUsing12, freqHz, iCalibL, iCalibH);
            [iFirstList, iLastList] = bicas.proc_utils.index_edges_2_first_last(iEdgeList);
            for iSubseq = 1:length(iFirstList)
                
                iFirst = iFirstList(iSubseq);
                iLast  = iLastList (iSubseq);
                
                % Extract SCALAR settings to use for entire subsequence of records.
                MUX_SET_ss    = MUX_SET  (iFirst);
                DIFF_GAIN_ss  = DIFF_GAIN(iFirst);
                dlrUsing12_ss = dlrUsing12(iFirst);
                iCalibL_ss    = iCalibL(iFirst);
                iCalibH_ss    = iCalibH(iFirst);
                freqHz_ss     = freqHz(iFirst);
                
                bicas.logf('info', ['Records %5i-%5i : ', ...
                    'MUX_SET=%3i; DIFF_GAIN=%3i; dlrUsing12=%i; freqHz=%5g; iCalibL=%i; iCalibH=%i'], ...
                    iFirst, iLast, ...
                    MUX_SET_ss, DIFF_GAIN_ss, dlrUsing12_ss, freqHz_ss, iCalibL_ss, iCalibH_ss)

                %============================================
                % FIND DEMUXER ROUTING, BUT DO NOT CALIBRATE
                %============================================
                % NOTE: Call demultiplexer with no samples. Only collecting information on which BLTS channels are
                % connected to which ASRs.
                [BltsSrcAsrArray, ~] = bicas.demultiplexer.main(MUX_SET_ss, dlrUsing12_ss, {[],[],[],[],[]});



                % Extract subsequence of DATA records to "demux".
                %DemuxerInputSubseq = bicas.proc_utils.select_row_range_from_struct_fields(samplesCaTm, iFirst, iLast);
                ssSamplesTm               = bicas.proc_utils.select_row_range_from_cell_comps(samplesCaTm, iFirst, iLast);
                ssNValidSamplesPerRecord = nValidSamplesPerRecord(iFirst:iLast);
                if hasSnapshotFormat
                    % NOTE: Vector of constant numbers (one per snapshot).
                    ssDtSec = 1 ./ freqHz(iFirst:iLast);
                else
                    % NOTE: Scalar (one for entire sequence).
                    ssDtSec = double(Epoch(iLast) - Epoch(iFirst)) / (iLast-iFirst) * 1e-9;   % TEMPORARY
                end

                %===========
                % CALIBRATE
                %===========
                ssSamplesAVolt = cell(5,1);
                for iBlts = 1:5

                    if strcmp(BltsSrcAsrArray(iBlts).category, 'Unknown')
                        % Calibrated data is NaN.
                        ssSamplesAVolt{iBlts} = NaN * zeros(size(ssSamplesTm{iBlts}));

                    elseif strcmp(BltsSrcAsrArray(iBlts).category, 'GND') || strcmp(BltsSrcAsrArray(iBlts).category, '2.5V Ref')
                        % No calibration.
                        ssSamplesAVolt{iBlts} = ssSamplesTm{iBlts};

                    else
                        if ~disableCalibration
                            % CASE: NOMINAL CALIBRATION
                            biasHighGain = DIFF_GAIN_ss;    % NOTE: Not yet sure that this is correct.

                            if hasSnapshotFormat
                                ssSamplesCaTm = bicas.proc_utils.convert_matrix_to_cell_array_of_vectors(...
                                    double(ssSamplesTm{iBlts}), ssNValidSamplesPerRecord);
                            else
                                assert(all(nValidSamplesPerRecord == 1))
                                
                                ssSamplesCaTm = {double(ssSamplesTm{iBlts})};
                            end

                            % CALIBRATE
                            %
                            % Function handle interface:
                            %   calibFunc = @(dtSec, lfrSamplesTm, iBlts, BltsSrc, biasHighGain, iCalibTimeL, iCalibTimeH, iRecord)
                            ssSamplesCaAVolt = calibFunc(...
                                ssDtSec, ssSamplesCaTm, iBlts, BltsSrcAsrArray(iBlts), biasHighGain, ...
                                iCalibL_ss, iCalibH_ss, iFirst);
                            
                            if hasSnapshotFormat
                                [ssSamplesAVolt{iBlts}, ~] = bicas.proc_utils.convert_cell_array_of_vectors_to_matrix(...
                                    ssSamplesCaAVolt, size(ssSamplesTm{iBlts}, 2));
                            else
                                ssSamplesAVolt{iBlts} = ssSamplesCaAVolt{1};   % NOTE: Must be column array.
                            end
                            
                        else
                            % CASE: CALIBRATION DISABLED.
                            ssSamplesAVolt{iBlts} = double(ssSamplesTm{iBlts});
                        end
                    end
                end
                
                %====================
                % CALL DEMULTIPLEXER
                %====================
                [~, SsAsrSamplesVolt] = bicas.demultiplexer.main(MUX_SET_ss, dlrUsing12_ss, ssSamplesAVolt);
                
                % Add demuxed sequence to the to-be complete set of records.
                %DemuxerOutput = bicas.proc_utils.add_rows_to_struct_fields(DemuxerOutput, DemuxerOutputSubseq);
                AsrSamplesAVolt = bicas.proc_utils.add_rows_to_struct_fields(AsrSamplesAVolt, SsAsrSamplesVolt);
                
            end
            
        end   % simple_demultiplex



    end   % methods(Static, Access=private)
        
end
