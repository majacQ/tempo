classdef UFMF < handle
    
    properties (SetAccess=private)
        version = 4
    end
    
    properties
        path
        
        numMeans = 1
    	bgUpdateSecs = 10
    	bgInitialMeans = 0
    	bgThreshold = 10
        
        useBoxes = true
        minimizeBoxes = false
        smallestBoxSize = 1
        
        frameRate
        frameCount = 0
        
        printStats = false
        drawBoxes = false
    end
    
    properties (Access=private)
        fileID
        isReadOnly
        isWritable
        
        % Reading
        pixelCoding = ''
        colorsPerPixel
        bytesPerPixel
        pixelDataClass
        frames
        keyFrames
        boxesAreFixedSize
        boxMaxSize          % height, width
        
        % Writing
        bgModel
        bgHasBeenUpdated = false
        frameIndex
        frameStats
    end
    
    properties (Constant, Access=private)
        KEYFRAME_CHUNK = 0
        FRAME_CHUNK = 1
        INDEX_DICT_CHUNK = 2
        
        MEAN_KEYFRAME_TYPE = 'mean'
        
        DICT_START_CHAR = 'd'
        ARRAY_START_CHAR = 'a'
    end
    
    
    methods (Static)
        
        function obj = openFile(filePath)
            obj = UFMF(filePath, 'read');
        end
        
        
        function obj = createFile(filePath)
            obj = UFMF(filePath, 'write');
        end
        
        
        function isUFMF = isUFMFFile(filePath)
            isUFMF = false;
            
            if exist(filePath, 'file')
                % Check if the file has 'ufmf' for its first four byte.
                fid = fopen(filePath, 'rb' , 'ieee-le');
                if fid >= 0
                    try
                        s = fread(fid, [1, 4], '*char');
                        isUFMF = strcmp(s, 'ufmf');
                        fclose(fid);
                    catch ME
                        fclose(fid);
                        rethrow(ME);
                    end
                end
            end
        end
    end
    
    
    methods
        
        function obj = UFMF(filePath, mode)
            obj.path = filePath;
            
            if nargin < 2
                % If a file exists at the path then read it, otherwise write to it.
                if exist(filePath, 'file')
                    mode = 'read';
                else
                    mode = 'write';
                end
            end
            
            if strcmp(mode, 'read')
                % Open the UFMF file for reading, binary, little-endian
                obj.fileID = fopen(filePath, 'rb' , 'ieee-le');
                if obj.fileID < 0
                    error('UFMF:IOError', 'Could not open UFMF file for reading.');
                end
                obj.isReadOnly = true;
                obj.isWritable = false;
                
                obj.readHeader();
            elseif strcmp(mode, 'write')
                % Open the UFMF file for writing.
                obj.fileID = fopen(filePath, 'w');
                if obj.fileID < 0
                    error('UFMF:IOError', 'Could not open UFMF file for writing.');
                end
                obj.isReadOnly = false;
                obj.isWritable = true;
                
                obj.frameStats = struct('bytes', [],'components',[]);
            else
                error('UFMF:ValueError', 'Invalid mode given for opening a UFMF file: %s', mode);
            end
        end
        
        
        function im = getFrame(obj, frameInd)
            % Read in a frame
            % TODO: cache frames
            
            if ~ismember(lower(obj.pixelCoding), {'mono8','rgb8'})
                error('Colorspace ''%s'' is not yet supported.  Only MONO8 and RGB8 allowed.', obj.pixelCoding);
            end
            
            im = obj.readFrame(uint64(frameInd));
        end
        
        
        function im = getFrameAtTime(obj, frameTime)
            % TODO: this assumes a constant frame rate, would be better to lookup the index from the time stamps but it will be slow...
            frameInd = obj.frameRate * frameTime + 1;
            
            im = obj.getFrame(frameInd);
        end
        
        
        function addFrame(obj, frameImage, frameIndex, frameTime)
            if obj.isReadOnly
                error('UFMF:ReadOnly', 'This UFMF file is only available for reading.');
            end
            if ~obj.isWritable
                error('UFMF:FileIsClosed', 'This UFMF file has been closed.');
            end
            
            if nargin < 3
                % Determine the frame index and time automatically from frame rate, etc.
                frameIndex = obj.frameCount + 1;
                frameTime = frameIndex / obj.frameRate;
            end
            
            if obj.frameCount == 0
                % Perform initial set up when the first frame comes in.
                obj.setupBGModel();
                obj.writeHeader(frameImage);
                obj.updateBGModel(frameImage, frameIndex, frameTime);
            end
            
            % Update the background model if necessary.
            if ~obj.bgHasBeenUpdated && frameTime > obj.bgUpdateSecs
                obj.updateBGModel(frameImage, frameIndex, frameTime);
                obj.bgHasBeenUpdated = true;
            end
            
            % Write the frame itself.
            obj.writeFrame(frameImage, frameIndex, frameTime);
            
            obj.frameCount = obj.frameCount + 1;
        end
        
        
        function [coding, colorsPerPixel, bytesPerPixel] = coding(obj)
            coding = obj.pixelCoding;
            if nargout > 1
                colorsPerPixel = obj.colorsPerPixel;
                if nargout > 2
                    bytesPerPixel = obj.bytesPerPixel;
                end
            end
        end
        
        
        function close(obj)
            if ~isempty(obj.fileID)
                if ~obj.isReadOnly && obj.isWritable
                    % Finish writing to the file.
                    obj.writeIndex();

                    obj.isWritable = false;

                    if obj.printStats
                        if obj.useBoxes
                            fprintf('UFMF: Mean frame size: %g KB, %d components\n', mean([obj.frameStats.bytes]) / 1024, ...
                                                                                     uint16(mean([obj.frameStats.components])));
                        else
                            fprintf('UFMF: Mean frame size: %g KB\n', mean([obj.frameStats.bytes]) / 1024);
                        end
                    end
                end
                
                fclose(obj.fileID);
                obj.fileID = [];
            end
        end
        
        
        function delete(obj)
            if ~isempty(obj.fileID)
                fclose(obj.fileID);
            end
        end
        
    end
    
    
    %% UFMF Reading
    
    
    methods (Access = private)
        
        function readHeader(obj)
            % ufmf: 4 bytes
            s = fread(obj.fileID, [1,4],'*char');
            if ~strcmp(s, 'ufmf')
                error('Invalid UFMF file: first four bytes must be ''ufmf''.');
            end

            % version: 4 bytes
            obj.version = fread(obj.fileID, 1, 'uint');
            if obj.version < 2
                error('Only UFMF versions 2-4 are supported.');
            end

            % index location: 8 bytes
            indexloc = fread(obj.fileID, 1, 'uint64');

            % this is somewhat backwards for faster reading
            % max_height: 2 bytes, max_width: 2 bytes
            obj.boxMaxSize = fread(obj.fileID, 2, 'ushort');

            % whether it is fixed size patches: 1 byte
            if obj.version >= 4
                obj.boxesAreFixedSize = (fread(obj.fileID, 1, 'uchar') == 1);
            else
                obj.boxesAreFixedSize = false;
            end

            % coding: 1 byte length then that many more bytes
            l = fread(obj.fileID, 1, 'uchar');
            obj.pixelCoding = fread(obj.fileID, [1, l], '*char');
            switch lower(obj.pixelCoding)
              case 'mono8'
                obj.colorsPerPixel = 1;
                obj.bytesPerPixel = 1;
              case 'rgb8'
                obj.colorsPerPixel = 3;
                obj.bytesPerPixel = 3;
            end
            obj.pixelDataClass = 'uint8'; 

            % seek to the start of the index
            fseek(obj.fileID, indexloc, 'bof');

            % read in the index
            index = obj.readDict();
            
            % Grab the key frame info from the index.
            obj.keyFrames = struct('type', cell(length(index.keyframe.mean.loc), 1), ...
                                   'fileLoc', num2cell(cast(index.keyframe.mean.loc, 'int64')), ...
                                   'timeStamp', num2cell(index.keyframe.mean.timestamp), ...
                                   'frameImage', cell(length(index.keyframe.mean.loc), 1));
            
            % Grab the frame info from the index.
            obj.frameCount = length(index.frame.loc);
            frameMeans = ones(obj.frameCount, 1) * length(obj.keyFrames);  % Assume all use the last one to start with.
            for i = 1:length(obj.keyFrames)-1
                idx = index.frame.timestamp >= index.keyframe.mean.timestamp(i) & ...
                      index.frame.timestamp < index.keyframe.mean.timestamp(i + 1);
                frameMeans(idx) = i;
            end
            obj.frames = struct('fileLoc', num2cell(cast(index.frame.loc, 'int64')), ...
                                'timeStamp', num2cell(index.frame.timestamp), ...
                                'meanIndex', num2cell(frameMeans), ...
                                'frameImage', cell(length(index.frame.loc), 1));
            
            if isempty(obj.frameRate)
                % Assume a constant frame rate based on the frame count and first and last time stamps.
                obj.frameRate = (obj.frameCount - 1) / (obj.frames(end).timeStamp - obj.frames(1).timeStamp);
            end
        end
        
        
        function index = readDict(obj)
            % read in a 'd': 1 byte
            chunktype = fread(obj.fileID, 1,'*char');
            if chunktype ~= obj.DICT_START_CHAR
                error('Error reading index: dictionary does not start with ''%s''.', obj.DICT_START_CHAR);
            end

            % read in the number of fields: 1 byte
            nkeys = fread(obj.fileID, 1,'uchar');

            for j = 1:nkeys
                
                % read the length of the key name: 2 bytes
                l = fread(obj.fileID, 1,'ushort');
                % read the key name: l byte
                key = fread(obj.fileID, [1,l],'*char');
                % read the next letter to tell if it is an array or another dictionary
                chunktype = fread(obj.fileID, 1,'*char');
                if chunktype == obj.DICT_START_CHAR
                    % if it's a 'd', then step back one char and read in the dictionary
                    % recursively
                    fseek(obj.fileID, -1,'cof');
                    index.(key) = obj.readDict();
                elseif chunktype == obj.ARRAY_START_CHAR
                    % array

                    % read in the data type
                    dtypechar = fread(obj.fileID, 1,'*char');
                    [matlabclass,bytes_per_element] = dtypechar2matlabclass(dtypechar);

                    % read in number of bytes
                    l = fread(obj.fileID, 1,'ulong');
                    n = l / bytes_per_element;
                    if n ~= round(n)
                        error('Length in bytes %d is not divisible by bytes per element %d',l,bytes_per_element);
                    end

                    % read in the index array
                    [index.(key),ntrue] = fread(obj.fileID, n,['*',matlabclass]);
                    if ntrue ~= n
                        warning('Could only read %d/%d bytes for array %s of index',n,ntrue,key);
                    end
                else
                    error('Error reading dictionary %s. Expected either ''%s'' or ''%s''.', key, obj.DICT_START_CHAR, obj.ARRAY_START_CHAR);
                end

            end
        end
        
        
        function [frameImage, timeStamp] = readKeyFrame(obj, keyFrameIndex)
            if keyFrameIndex < 1 || keyFrameIndex > length(obj.keyFrames)
                error('UFMF:RangeError', 'There is no key frame at index %d', keyFrameIndex);
            end
            
            fseek(obj.fileID, obj.keyFrames(keyFrameIndex).fileLoc, 'bof');
            
            % chunktype: 1 byte
            chunkType = fread(obj.fileID, 1, 'uchar');
            if chunkType ~= obj.KEYFRAME_CHUNK
                error('Expected chunktype = %d at start of keyframe.');
            end
            
            % keyframe type 1 byte length followed by that number of bytes
            typeLength = fread(obj.fileID, 1, 'uchar');
            obj.keyFrames(keyFrameIndex).type = fread(obj.fileID, [1, typeLength], '*char');
            
            % data type
            dtypechar = fread(obj.fileID, 1, '*char');
            matlabclass = dtypechar2matlabclass(dtypechar);

            % images are sideways: swap width and height
            % width, height
            sz = double(fread(obj.fileID, 2, 'ushort'));
            height = sz(1);
            width = sz(2);

            % timestamp
            timeStamp = fread(obj.fileID, 1, 'double');

            % actual frame data
            % TODO: handle colorspaces other than RGB8 and MONO8
            frameImage = fread(obj.fileID, width * height * obj.bytesPerPixel, ['*', matlabclass]);
            frameImage = reshape(frameImage, [obj.colorsPerPixel, height, width]);
            
            obj.keyFrames(keyFrameIndex).frameImage = frameImage;
        end
        
        
        function [frameImage, timeStamp] = readFrame(obj, frameIndex)
            frame = obj.frames(frameIndex);
            
            fseek(obj.fileID, frame.fileLoc, 'bof');
            
            % read in the chunk type: 1 byte
            chunkType = fread(obj.fileID, 1,'uchar');
            if chunkType ~= obj.FRAME_CHUNK
                error('Expected chunktype = %d at start of frame, got %d', FRAME_CHUNK, chunkType);
            end
            % read in timestamp: 8 bytes
            timeStamp = fread(obj.fileID, 1,'double');
            if obj.version == 4
                % number of points: 4
                boxCount = fread(obj.fileID, 1,'uint32');
            else
                % number of points: 2
                boxCount = fread(obj.fileID, 1,'ushort');
            end
            %fprintf('nforeground boxes = %d\n',npts);
            
            % Get the pixel content of the boxes.
            % TODO: handle colorspaces other than MONO8 and RGB8
            if obj.boxesAreFixedSize
                % TODO: untested block
                
                boxes = fread(obj.fileID, boxCount*2,'uint16');
                boxes = reshape(boxes,[boxCount,2]);
                % read sideways
                boxes = boxes(:,[2,1]);
                data = fread(obj.fileID, boxCount* obj.boxMaxSize(2) * obj.boxMaxSize(1) * obj.bytesPerPixel,['*', obj.pixelDataClass]);
                data = reshape(data,[obj.colorsPerPixel, boxCount, obj.boxMaxSize(1), obj.boxMaxSize(2)]);
            else
                boxes = zeros(boxCount, 4);
                data = cell(1, boxCount);
                
                % TODO: why read just the very last frame differently?
                if frameIndex == obj.frameCount
                    for i = 1:boxCount
                        boxes(i,:) = fread(obj.fileID, 4,'ushort');
                        width = boxes(i,4);
                        height = boxes(i,3);
                        data{i} = fread(obj.fileID, width * height * obj.bytesPerPixel, ['*', obj.pixelDataClass]);
                        data{i} = reshape(data{i}, [obj.colorsPerPixel, height, width]);
                    end
                else
                    byteCount = (obj.frames(frameIndex + 1).fileLoc - frame.fileLoc + 1) * obj.bytesPerPixel;
                    allBoxData = fread(obj.fileID, byteCount, ['*', obj.pixelDataClass]);
                    dataIndex = 1;
                    for i = 1:boxCount
                        tmp = double(allBoxData(dataIndex:(dataIndex+7)));
                        boxes(i,:) = tmp(1:2:7) + 256 * tmp(2:2:8);
                        width = boxes(i, 4);
                        height = boxes(i, 3);
                        byteCount = width * height * obj.bytesPerPixel;
                        data{i} = allBoxData((dataIndex+8):(dataIndex + 7 + byteCount));
                        dataIndex = dataIndex + 8 + byteCount;
                        data{i} = reshape(data{i}, [obj.colorsPerPixel, height, width]);
                    end
                end
                % images are read sideways
                boxes = boxes(:,[2,1,4,3]);
            end
            % matlab indexing
            boxes(:,1:2) = boxes(:,1:2)+1;
            
            % Start with the most recent key frame.
            frameImage = obj.keyFrames(frame.meanIndex).frameImage;
            if isempty(frameImage)
                frameImage = obj.readKeyFrame(frame.meanIndex);
            end
            if ~strcmp(obj.keyFrames(frame.meanIndex).type, obj.MEAN_KEYFRAME_TYPE)
                error('UFMF:TypeError', 'Expected keyframe type = ''%s'' at start of mean keyframe', obj.MEAN_KEYFRAME_TYPE);
            end
            
            % Now fill in the boxes of pixels from the frame itself.
            if obj.boxesAreFixedSize
                % TODO: untested block
                
                % sparse image
                if obj.boxMaxSize(1) == 1 && obj.boxMaxSize(2) == 1
                    tmp = false(header.nr,header.nc);
                    tmp(sub2ind(size(tmp),boxes(:,2),boxes(:,1))) = true;
                    frameImage(:,tmp) = data;
                else
                    for i = 1:boxCount
                        frameImage(:,boxes(i,2):boxes(i,2)+max_height-1,boxes(i,1):boxes(i,1)+max_width-1) = data(:,i,:,:);
                    end
                end
            else
                for i = 1:boxCount
                    box = boxes(i, :);
                    frameImage(:, box(2):box(2)+box(4)-1, box(1):box(1)+box(3) - 1) = data{i};
                end
                if obj.drawBoxes
                    % Outline each box in red.
                    boxColor = [255; 0; 0];
                    for i = 1:boxCount
                        box = boxes(i, :);
                        frameImage(:, box(2):box(2)+box(4)-1, box(1)) = repmat(boxColor, [1 box(4)]);
                        frameImage(:, box(2):box(2)+box(4)-1, box(1)+box(3)-1) = repmat(boxColor, [1 box(4)]);
                        frameImage(:, box(2)+box(4)-1, box(1):box(1)+box(3)-1) = repmat(boxColor, [1 box(3)]);
                        frameImage(:, box(2),          box(1):box(1)+box(3)-1) = repmat(boxColor, [1 box(3)]);
                    end
                end
            end

            frameImage = permute(frameImage,[3,2,1]);
        end
        
    end
    
    
    %% UFMF Writing
    
    methods (Access = private)
        
        function setupBGModel(obj)
            % Set up the initial background model.
            obj.frameIndex.loc = [];
            obj.frameIndex.locLoc = [];
            obj.bgModel.lastkeyframetime = -inf;
            tmp = struct('loc', cast([], 'int64'),'timestamp',[]);
            obj.frameIndex.frame = tmp;
            obj.frameIndex.keyframe.mean = tmp;
            obj.bgModel.nframes = 0;
            obj.bgModel.meanImage = [];
            obj.bgModel.lastupdatetime = -inf;
        end
        
        
        function updateBGModel(obj, frameImage, frameIndex, timeStamp)
            % set time of this update
            obj.bgModel.lastupdatetime = timeStamp;

            % update nframes
            n = min(obj.bgModel.nframes + 1, obj.numMeans);
            obj.bgModel.nframes = n;

            % update the mean image
            % TODO: investigate whether we should be storing the mean image as a double cuz
            % matlab's image arithmetic functions suck. 
            if isempty(obj.bgModel.meanImage)
                %[rows, columns, colors] = size(frameImage);
                obj.bgModel.meanImage = uint8(frameImage); %zeros([rows, columns, colors], 'uint8');
            else
                obj.bgModel.meanImage = imlincomb((n-1)/n, obj.bgModel.meanImage, ...
                                                      1/n, frameImage);
            end
            obj.writeKeyFrame(timeStamp);

            if obj.printStats && frameIndex >= obj.bgInitialMeans
                fprintf('UFMF: BG update %d at %s\n', obj.bgModel.nframes, num2str(timeStamp));
            end
        end
        
        
        function [boundingBoxes, diffImage] = subtractBackground(obj, frameImage)
            % Perform background substraction.
            diffImage = imabsdiff(frameImage, obj.bgModel.meanImage);
            
            % Convert to grayscale if needed.
            ncolors = size(diffImage, 3);
            if ncolors > 1
              diffImage = sum(diffImage, 3) / ncolors;
            end
            
            % Find pixels that vary more than the threshold.
            diffImage = diffImage >= obj.bgThreshold;       
            
            if obj.useBoxes
                if obj.minimizeBoxes
                    % Try to reduce the number of connected components.
                    diffImage = imdilate(diffImage, strel('square', 2));
                    diffImage = imfill(diffImage, 'holes');
                    if obj.smallestBoxSize > 1
                        % Remove isolated pixels.
                        diffImage = bwareaopen(diffImage, obj.smallestBoxSize);
                    end
                end
                
                % subplot(1,2,1);image(frameImage);axis image;subplot(1,2,2);imagesc(diffImage);axis image;
                
                boundingBoxes = regionprops(bwconncomp(diffImage),'boundingbox');
                boundingBoxes = cat(1, boundingBoxes.BoundingBox);
                    
                if obj.minimizeBoxes
                    % TODO: Use an R-Tree (http://en.wikipedia.org/wiki/R-tree) to deal with
                    %       overlapping and/or nearby boxes.
                    
                    % Remove any boxes that are inside others.
                    boxSizes = boundingBoxes(:,3) .* boundingBoxes(:,4);
                    [~, sortInd] = sort(boxSizes);
                    boundingBoxes = boundingBoxes(sortInd, :);
                    boxCount = size(boundingBoxes, 1);
                    littleBoxInd = 1;
                    while littleBoxInd < boxCount
                        bigBoxInd = littleBoxInd + 1;
                        while bigBoxInd <= boxCount
                            littleBox = boundingBoxes(littleBoxInd, :);
                            bigBox = boundingBoxes(bigBoxInd, :);
                            
                            % If the little box is entirely inside the big one then we don't need it.
                            if littleBox(1) >= bigBox(1) && ...
                               littleBox(1) + littleBox(3) <= bigBox(1) + bigBox(3) && ...
                               littleBox(2) >= bigBox(2) && ...
                               littleBox(2) + littleBox(4) <= bigBox(2) + bigBox(4)
                                boundingBoxes(littleBoxInd, :) = [];
                                boxCount = boxCount - 1;
                                littleBoxInd = littleBoxInd - 1;
                                break
                            end
                            
                            bigBoxInd = bigBoxInd + 1;
                        end
                        littleBoxInd = littleBoxInd + 1;
                    end
                end
            else
                [y, x] = find(diffImage);
                boundingBoxes = [x, y] - .5;
                boundingBoxes(:, 3:4) = 1;
            end
        end
        
        
        function writeHeader(obj, frameImage)
            if size(frameImage, 3) == 3
                coding = 'RGB8';
            else
                coding = 'MONO8';
            end

            if obj.useBoxes
                max_width = size(frameImage, 2);
                max_height = size(frameImage, 1);
            else
                max_width = 1;
                max_height = 1;  
            end

            % ufmf: 4
            fwrite(obj.fileID,'ufmf','schar');
            % version: 4
            fwrite(obj.fileID, obj.version, 'uint');
            % index location: 0 for now: 8
            obj.frameIndex.locLoc = ftell(obj.fileID);
            fwrite(obj.fileID, 0, 'uint64');

            % max width: 2
            fwrite(obj.fileID, max_height, 'ushort');
            % max height: 2
            fwrite(obj.fileID, max_width, 'ushort');
            % whether it is fixed size patches: 1
            fwrite(obj.fileID, ~obj.useBoxes, 'uchar');
            % raw coding string length: 1
            fwrite(obj.fileID, length(coding), 'uchar');
            % coding: length(coding)
            fwrite(obj.fileID, coding);
        end
        
        
        function writeKeyFrame(obj, timeStamp)
            keyframe_type = 'mean';

            % update lastkeyframetime
            obj.bgModel.lastkeyframetime = timeStamp;

            loc = ftell(obj.fileID);
            % store in index
            obj.frameIndex.keyframe.mean.loc(end+1) = loc;
            % also store timestamp
            obj.frameIndex.keyframe.mean.timestamp(end+1) = timeStamp;

            % write the chunk type
            fwrite(obj.fileID, obj.KEYFRAME_CHUNK, 'uchar');
            % write the keyframe type
            fwrite(obj.fileID, length(keyframe_type), 'uchar');
            fwrite(obj.fileID, keyframe_type, 'char');

            % write the data type (based on format characters from http://docs.python.org/2/library/struct.html)
            dtype = matlabclass2dtypechar(class(obj.bgModel.meanImage));
            fwrite(obj.fileID, dtype, 'char');

            % images are sideways: swap width and height
            % width, height
            fwrite(obj.fileID,[size(obj.bgModel.meanImage,2),size(obj.bgModel.meanImage,1)],'ushort');

            % timestamp
            fwrite(obj.fileID,timeStamp,'double');

            % write the frame
            fwrite(obj.fileID,permute(obj.bgModel.meanImage,[3,2,1]),class(obj.bgModel.meanImage));
        end
        
        
        function writeFrame(obj, frameImage, frameIndex, timeStamp)
            [boundingBoxes, diffImage] = subtractBackground(obj, frameImage);
            ncc = size(boundingBoxes, 1);
            
            % get location of this frame
            loc = ftell(obj.fileID);
            % store in index
            obj.frameIndex.frame.loc(end+1) = loc;
            % also store timestamp
            obj.frameIndex.frame.timestamp(end+1) = timeStamp;

            % write chunk type: 1
            fwrite(obj.fileID, obj.FRAME_CHUNK, 'uchar');
            % write timestamp: 8
            fwrite(obj.fileID, timeStamp, 'double');
            % write number of points: 4
            fwrite(obj.fileID, ncc, 'uint32');

            dtype = class(frameImage);
            if obj.useBoxes
              for j = 1:ncc
                fwrite(obj.fileID, [boundingBoxes(j,[1,2])-.5,boundingBoxes(j,[3,4])], 'ushort');
                tmp = frameImage(boundingBoxes(j,2)+.5:boundingBoxes(j,2)+boundingBoxes(j,4)-.5,boundingBoxes(j,1)+.5:boundingBoxes(j,1)+boundingBoxes(j,3)-.5,:);
                fwrite(obj.fileID, permute(tmp,[3,2,1]), dtype);
              end
            else
                %   % this is kind of complicated because the coordinates must be ushorts and
                %   % the pixels must be uint8s.
                %   tmp = permute(im,[3,1,2]);
                %   fwrite(fid,cat( 1, reshape(typecast( cast(bb(:,2)'-.5,'uint16'), 'uint8' ),[2,ncc]), ...
                %     reshape(typecast( cast(bb(:,1)'-.5,'uint16'), 'uint8' ),[2,ncc]), ...
                %     cast(tmp(:,isfore), 'uint8') ),'uint8');

                % faster to write in this order in Matlab: all pixel locations followed
                % by all pixels; doing the complicated stuff above works almost as fast,
                % but is ... complicated. 
                fwrite(obj.fileID, boundingBoxes(:,[2,1])-.5,'ushort');
                tmp = permute(frameImage,[3,2,1]);
                % index by color, then column, then row
                fwrite(obj.fileID, tmp(:,diffImage), dtype);
            end
            
            obj.frameStats(frameIndex).bytes = ftell(obj.fileID) - loc - (1 + 8 + 4);
            obj.frameStats(frameIndex).components = ncc;
        end
        
        
        function writeIndex(obj)
            % Finish writing the UFMF by writing the indices to the file and closing.
            % We write the index at the end of the file using subfunction write_dict.
            % We store the location of the index in the file at the location stored in
            % obj.frameIndex.locLoc. 

            % start of index chunk
            fwrite(obj.fileID, obj.INDEX_DICT_CHUNK, 'uchar');
            obj.frameIndex.loc = ftell(obj.fileID);
            
            % write index
            obj.writeDict(obj.frameIndex);

            fseek(obj.fileID, obj.frameIndex.locLoc, 'bof');
            fwrite(obj.fileID, obj.frameIndex.loc,'uint64');
        end
        
        
        function writeDict(obj, dict)
            keys = fieldnames(dict);

            % write a d
            fwrite(obj.fileID, 'd');
            % write the number of fields
            fwrite(obj.fileID, length(keys), 'uchar');

            for j = 1:length(keys)
                key = keys{j};
                value = dict.(key);
                % write length of key name
                fwrite(obj.fileID, length(key), 'ushort');
                % write the key
                fwrite(obj.fileID, key);
                % if this is a struct, call recursively
                if isstruct(value)
                    obj.writeDict(value);
                else
                    % write a for array followed by the single char abbr of the class
                    dtypechar = matlabclass2dtypechar(class(value));
                    fwrite(obj.fileID, ['a', dtypechar]);
                    % write length of array * bytes_per_element
                    tmp = whos('value');
                    fwrite(obj.fileID, tmp.bytes, 'ulong');
                    % write the array
                    fwrite(obj.fileID, value, class(value));
                end
            end
        end
    end
end
    
    
