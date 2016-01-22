classdef mms_db_sql < handle
	%MMS_DB_SQL handle MMS database of files and variables in SQLITE
	%   IN DEVELOPMENT, DO NOT USE!!!!
	
	properties (Access=protected)
		connection = [];
		statement
		databaseDirectory
	end
	
	properties
		databaseFile
	end
	
	properties (Dependent = true)
		isConnected
	end
	
	methods
		function obj = mms_db_sql(fileName)
          javaPath=[irf('path'), filesep, 'contrib', filesep, 'java', filesep];
          listDir=dir([javaPath, 'sqlite-jdbc*.jar']);
          if(isempty(listDir)), error('Missing sqlite-jdbc.jar'); end
          javaaddpath([javaPath, listDir(end).name]);
			if nargin == 1,
				[dirPath,file,ext] = fileparts(fileName);
				if isempty(dirPath) || dirPath == '.'
					dirPath = pwd;
				end
				obj.databaseDirectory = dirPath;
				obj.databaseFile = [dirPath filesep file ext];
				obj.open_database;
			end
		end
		
		function open_database(obj)
			% Create tables if not exist
			sql = [...
				'CREATE TABLE IF NOT EXISTS "FileList" ('...
				'"idFile"	INTEGER, "directory","dataset","date","version","fileNameFullPath"	TEXT UNIQUE,'...
				'	PRIMARY KEY(idFile) );'...
				'CREATE TABLE IF NOT EXISTS "FileListToImport" '...
				'("directory","dataset","date","version","fileNameFullPath"	TEXT UNIQUE);'...
				'CREATE TABLE IF NOT EXISTS "VarNames" ('...
				'"varId"	INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,"varName"	TEXT, "idDataset" INTEGER NOT NULL);'...
				'CREATE TABLE IF NOT EXISTS "Datasets" ('...
				'"idDataset"	INTEGER NOT NULL,"dataset"	TEXT,"varNames"	TEXT,PRIMARY KEY(idDataset));'...
				'CREATE TABLE IF NOT EXISTS "VarIndex" ('...
				'"idFile"	INTEGER,"idDataset"	TEXT,"startTT"	INTEGER,"endTT"	INTEGER, PRIMARY KEY (idFile,idDataset));'...
				];
			obj.sqlUpdate(sql);
		end
		
		function connect(obj)
			% CONNECT open connection to database
			if ~obj.isConnected
				d = org.sqlite.JDBC;
				p = java.util.Properties();
				obj.connection = d.createConnection(...
					['jdbc:sqlite:' obj.databaseFile],p);
				obj.statement = obj.connection.createStatement();
			end
		end
		
		function close(obj)
			% CLOSE close connection to database
			obj.connection.close % close connection
			obj.connection = [];
		end
		
		function value = get.isConnected(obj)
			if isempty(obj.connection)
				value = false;
			else
				value = true;
			end
		end
		
		
		function import_a_file_from_list(obj)
			% import one new file from FileListToImport
			sql = 'select * from FileListToImport LIMIT 1';
			rs = obj.sqlQuery(sql);
			while rs.next
				fileToImport = char(rs.getString('fileNameFullPath'));
				obj.import_file(fileToImport);
			end
			% remove file from FileListToImport
			sql = ['delete from FileListToImport where fileNameFullPath="' fileToImport '"'];
			obj.sqlUpdate(sql);
		end
		
		function import_files_from_list(obj)
			% import all files from FileListToImport
			someFilesDidNotImport = false;
			while 1
				sql = 'select * from FileListToImport';
				rs = obj.sqlQuery(sql);
				if rs.next
					fileToImport = char(rs.getString('fileNameFullPath'));
					irf.log('debug',['Importing ' fileToImport]);
					status = obj.import_file(fileToImport);
					if status == 0,
						irf.log('warning',['******** Did not succeed to import:',fileToImport]);
						someFilesDidNotImport = true;
					end
					% remove file from FileListToImport
					sql = ['delete from FileListToImport where fileNameFullPath="' fileToImport '"'];
					obj.sqlUpdate(sql);
				else
					if someFilesDidNotImport
						irf.log('critical','Some files did not import!');
						break;
					else
						irf.log('warning','All files imported from FileListToImport');
						break;
					end
				end
			end
		end
		
		function add_all_files_to_import_list(obj)
			% works only in unix or mac
			% Verify sqlite3 is installed
			[status, ~] = system('command -v sqlite3 >/dev/null 2>&1 || { exit 100; }');
			if(status==100), error('It appears Sqlite3 is not installed/found on your system.'); end
			system(['cd ' obj.databaseDirectory ...
				'; find ./mms[1-4]* -name *cdf -type f |  ' ...
				'perl -pe ''s/(\.\/mms.*)(mms[1-4]?_[\w-]*)_(20\d\d\d\d\d\d\d*)_(v[\d\.]*)(.cdf)\n/$1,$2,$3,$4,$_/'' > delme.txt;'...
				'echo -e ".mod csv\n.import delme.txt FileListToImport\n" | sqlite3 ' obj.databaseFile ';'...
				'rm ./delme.txt'...
				]);
		end
		
		function fileInfo = get_file_info(fileName)
			% GET_FILE_INFO get values of directory, dataset, date, version
			% fileInfo is structure with fields
			% 'directory','dataset','date',version'
			fileInfo = regexp(fileName,'(?<directory>\.\/mms.*)(?<dataset>mms[1-4]?_[\w-]*)_(?<date>20\d\d\d\d\d\d\d*)_(?<version>v[\d\.]*)(.cdf)','names');
		end
		
		function status = import_file(obj,fileToImport)
			% import a file
			irf.log('notice',['File to import: ' fileToImport]);
			status = 0;
			% check if file is not in db
			sql = ['select * from FileList ' ...
				'where fileNameFullPath = "' fileToImport '"'];
			rs=obj.sqlQuery(sql);
			while rs.next % file already exist
				irf.log('warning','File exists!');
				obj.close;
				return;
			end
			
			% add fileName to FileList and get idFile
			sql = ['insert into FileList (directory,dataset,date,version,fileNameFullPath)'...
				' SELECT * from FileListToImport where fileNameFullPath = "' fileToImport '"'];
			obj.sqlUpdate(sql);
			sql = ['select idFile,dataset from FileList where  fileNameFullPath = "' fileToImport '"'];
			rs=obj.sqlQuery(sql);
			while rs.next % file already exist
				idFile = char(rs.getString('idFile'));
				dataset = char(rs.getString('dataset'));
			end
			
			% add to VarIndex list
			out = obj.get_science_variables(fileToImport);
			if isempty(out) % reading cdf file did not succeed
				status = 0;
				return;
			end
			for iDataset = 1:numel(out)
				if isempty(out(iDataset).startTT) || out(iDataset).startTT<1000, break;end % energy channels are put as DEPEND_0 for FPI
				varNames = out(iDataset).varNames;
				% add dataset to Datasets if needed
				idDataset=obj.add_var_names(dataset,varNames);
                % Sqlite does not have NaN but uses NULL values..
                if(isnan(out(iDataset).startTT) || isnan(out(iDataset).endTT))
                  irf.log('debug',['.. insert into VarIndex: idDataset=' dataset ...
					' : "NULL"/"NULL" ']);
				  sql = ['insert into VarIndex (idFile,idDataset,startTT,endTT) '...
					'values (' idFile ',"' idDataset '", "NULL", "NULL")'];
                else
                  irf.log('debug',['.. insert into VarIndex: idDataset=' dataset ...
					' : ' irf_time(EpochTT([out(iDataset).startTT out(iDataset).endTT]),'tint>utc')]);
				  sql = ['insert into VarIndex (idFile,idDataset,startTT,endTT) '...
					'values (' idFile ',"' idDataset '",' ...
					num2str(out(iDataset).startTT) ',' num2str(out(iDataset).endTT) ')'];
                end
				obj.sqlUpdate(sql);
			end
			
			status = 1;
		end
		
		function idDataset=add_var_names(obj,dataset,varNames)
			if ischar(varNames), varNames = {varNames};end
			
			% Check if dataset with varNames exists
			varNamesCharArray = char(sort(varNames))';
			varNamesCharArray(:,end+1)=' ';
			varNamesString = reshape(varNamesCharArray,1,[]);
			rs = obj.sqlQuery(['select idDataset,dataset from Datasets where varNames="' varNamesString '";']);
			flagAddDatasetToDb = true;
			while rs.next
				datasetDb = char(rs.getString('dataset'));
				idDataset = char(rs.getString('idDataset'));
				if strcmp(datasetDb,dataset)
					flagAddDatasetToDb = false;
					break;
				end
				irf.log('warning',['! ' datasetDb ' and ' dataset ' include the same variables!']);
			end
			
			% add dataset and variables if needed and get idDataset
			if flagAddDatasetToDb
				% add dataset
				obj.sqlUpdate(['insert into Datasets(dataset,varNames) values("' dataset '","' varNamesString '");']);
				rs = obj.sqlQuery(['select idDataset from Datasets where dataset="' dataset '";']);
				while rs.next
					idDataset = char(rs.getString('idDataset'));
				end
				% add variables and idDataset
				for iVar = 1:length(varNames)
					sql = ['insert or ignore into VarNames(varName,idDataset) values("' varNames{iVar} '",'...
						idDataset ');'];
					obj.sqlUpdate(sql);
				end
			end
			
		end
		
		function [idDatasetList,DatasetList] = find_datasets_with_varname(obj,varName)
			% find Datasets with varName
			idDatasetList = {};iDataset = 1;
			sql = ['select * from VarNames where varName = "' varName '"'];
			rs=obj.sqlQuery(sql);
			if ~rs.next
				irf.log('warning',['There is no variable with name ' varName '.']);
				return;
			else
				while true
					idDatasetList{iDataset} = char(rs.getString('idDataset'));
					iDataset = iDataset +1 ;
					if ~rs.next, break; end
				end
			end
			if nargout == 2,
				DatasetList = idDatasetList;
				for iD = 1:numel(idDatasetList)
					rs = obj.sqlQuery(['select dataset from Datasets where idDataset = ' idDatasetList{iD} ';']);
					if rs.next
						DatasetList{iD} = char(rs.getString('dataset'));
					end
				end
			end
		end
		
		function tintArray = index_var(obj,varName)
			sql = ['select startTT,endTT from VarIndex where idDataset in ('...
				'select idDataset from VarNames where varName = "' varName '") order by startTT asc'];
			rs= obj.sqlQuery(sql);
			tintArray = zeros(0,2,'int64');
			while rs.next
				tint = sscanf([char(rs.getString('startTT')) ' ' ...
					char(rs.getString('endTT'))],'%ld %ld');
				tintArray(end+1,:)= tint;
			end
			if nargout == 0, % print time intervals
				nTint = size(tintArray,1);
				for ii = 1:min(nTint,5),       disp(irf_time(tintArray(ii,:),'tint>utc')); end
				if nTint>10,                   disp('...'); end
				for ii = max(5,nTint-5):nTint, disp(irf_time(tintArray(ii,:),'tint>utc')); end
				clear tintArray;
			end
		end
		
		function fileNames = search_files(obj,varName,timeInterval)
			% SEARCH FILES search files given variable name and time interval
			%
			% SEARCH_FILES(obj,varName,timeInterval)
			%  time interval can be UTC string or GenericTimeArray
			if nargin < 3
				startTT = int64(0);
				endTT = intmax('int64');
			else
				if ischar(timeInterval)
					timeInterval = irf.tint(timeInterval);
				elseif ~isa(timeInterval,'GenericTimeArray')
					irf.log('warning','Time interval in unknown format');
					return;
				end
				startTT = timeInterval.start.ttns;
				endTT = timeInterval.stop.ttns;
			end
			if ~ischar(varName),
				irf.log('critical','varName should be text string');
				return;
			elseif ~isinteger(startTT) && ~isinteger(endTT),
				irf.log('critical','startTT and endTT should be integers');
				return;
			end
			% find Datasets with varName
			idDatasetList = find_datasets_with_varname(obj,varName);
			
			% find files
			idFileArray = []; iFile = 1;
			for iDataset = 1:length(idDatasetList)
				sql = ['select idFile from VarIndex where idDataset = "' idDatasetList{iDataset} '"'];
				sql = [sql ' and startTT <= ' num2str(endTT)   ]; %#ok<AGROW>
				sql = [sql ' and   endTT >= ' num2str(startTT) ]; %#ok<AGROW>
				sql = [sql ' order by startTT asc'];              %#ok<AGROW>
				rs=obj.sqlQuery(sql);
				while rs.next
					idFileArray(iFile) = str2double(rs.getString('idFile')); %#ok<AGROW>
					irf.log('debug',['idFile = ' num2str(idFileArray(iFile))]);
					iFile = iFile + 1;
				end
			end
			
			% get filenames
			fileNames = cell(numel(idFileArray),1);
			for iFile = 1:numel(idFileArray)
				sql = ['select fileNameFullPath from FileList where idFile = ' ...
					num2str(idFileArray(iFile))];
				rs = obj.sqlQuery(sql);
				if rs.next
					fileNames{iFile} = char(rs.getString('fileNameFullPath'));
				end
			end
		end
		
		
		function var(obj,varargin)
			% VAR seach variable names
			%  VAR('par1','par2',..)
			%  finds variable name which contains a text string par1 and par2 and ...
			sql = 'select * from VarNames ';
			if nargin > 1,
				sql = [sql 'where '];
				for iVar = 1:nargin-1,
					if ischar(varargin{iVar})
						if iVar > 1,
							sql = [sql ' and ']; %#ok<AGROW>
						end
						sql = [sql ' varName like "%' strrep(varargin{iVar},'*','%') '%"']; %#ok<AGROW>
					end
				end
			end
			res=obj.sqlQuery(sql);
			while res.next
				disp(char(res.getString('varName')));
			end
		end
		
		function out = sqlQuery(obj,sql)
			obj.connect;
			irf.log('debug',['sqlite> ' sql]);
			out=obj.statement.executeQuery(sql);
		end
		
		function out = sqlUpdate(obj,sql)
			obj.connect;
			irf.log('debug',['sqlite> ' sql]);
			out=obj.statement.executeUpdate(sql);
		end
	end
	methods (Static)
		function out = get_science_variables(cdfFileName)
			% OUT returns structure array with fields
			%     epochVarName - name of the epoch variable, string
			%     varNames - cell array of strings with variables
			%     startTT  - int64 (TT2000 values) with corresponding start time
			%     endTT    - int64 (TT2000 values) with corresponding end time
			narginchk(1,1); % One file name
            if(~exist(cdfFileName, 'file'))
              errStr = ['File not found: ', cdfFileName];
              irf.log('critical', errStr); error(errStr);
            end
 			irf.log('debug',['Reading: ' cdfFileName]);
			try
				inf = spdfcdfinfo(cdfFileName);
            catch ME
              errStr = ['Cannot get file information from: ', cdfFileName];
              irf.log('warning', errStr); irf.log('warning', ME.message);
              warning(errStr);
              out = [];
              return;
			end
			dep = inf.VariableAttributes.DEPEND_0;
			[tVarNames,~,IC] = unique(dep(:,2));
			% FPI bug fix, removing energy_index and pitch_index from DEPEND_0
			%isGoodTVarName = cellfun(@(x) isempty(strfind(x,'index')),tVarNames);
			indGoodTVarName = 1:numel(tVarNames);
			iBadTVarName = find(~ismember(tVarNames,inf.Variables(:,1))); % time variable should be under inf.Variables(:,1)
			if any(iBadTVarName)
				indGoodTVarName(indGoodTVarName==iBadTVarName) = [];
				irf.log('notice',['!! bad time variable names in DEPEND_O: ' tVarNames{iBadTVarName}]);
				tVarNames{iBadTVarName} = [];
			end
			isBadTime  = cellfun(@(x) ~any(strcmpi({'tt2000','epoch','epoch16'}, ...
				inf.Variables(strcmp(inf.Variables(:,1), x),4))), tVarNames(indGoodTVarName));
			if any(isBadTime)
				irf.log('notice',['!! no accepted time format for time DEPEND_O variable: ' ...
					tVarNames{indGoodTVarName(isBadTime)}]);
				indGoodTVarName(isBadTime) = [];
			end
			% read time variables
            try
              epoch = spdfcdfread(cdfFileName, ...
				'Variable', tVarNames(indGoodTVarName), 'KeepEpochAsIs', true);
            catch ME
              errStr = ['Cannot read Epochs from file: ', cdfFileName];
              irf.log('warning', errStr); irf.log('warning', ME.message);
              warning(errStr); return;
            end
			if isinteger(epoch), epoch = {epoch};end % only one time variable
			for iT = numel(indGoodTVarName):-1:1
				out(iT).epochVarName = tVarNames{iT};
				out(iT).varNames = dep(IC == iT,1);
				startTT = min(epoch{indGoodTVarName(iT)});
				endTT   = max(epoch{indGoodTVarName(iT)});
				if any(startTT) && any(endTT) && ...
						(min(startTT,endTT) < int64(479390467184000000)...% '2015-03-12T00:00:00.000000000'
						||  max(startTT,endTT) > int64(1262260868184000000)),%'2040-01-01T00:00:00.000000000'
					out(iT).startTT = NaN;
					out(iT).endTT   = NaN;
					irf.log('notice',['!!! In file:' cdfFileName]);
					irf.log('notice',['!!! ' out(iT).epochVarName ' has startTT = ' num2str(startTT) ' and endTT = ' num2str(endTT)]);
				else
					out(iT).startTT = startTT;
					out(iT).endTT   = endTT;
				end
			end
		end
	end
	
end