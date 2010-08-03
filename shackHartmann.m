classdef shackHartmann < handle
    % SHACKHARTMANN Create a Shack-Hartmann object
    %
    % obj = shackHartmann(nLenslet,detectorResolution) creates a
    % Shack-Hartmann object with a (nLenslet X nLenslet) lenslet array and
    % a detector with a detectorResolution resolution
    %
    % obj = shackHartmann(nLenslet,detectorResolution,validLenslet) creates
    % a Shack-Hartmann object with a (nLenslet X nLenslet) lenslet array, a
    % detector with a detectorResolution resolution and a logical mask of
    % size nLenslet setting the location of the valid lenslets inside the
    % lenslet array
    %
    % See also: lensletArray, detector, source, lensletArrayHowto,
    % detectorHowto
    
    properties
        % lenslet array object
        lenslets;
        % detector object
        camera;
        % camera flat field
        flatField = 0;
        % camera pixel gains
        pixelGains = 1;
        % use quad-cell
        quadCell = false;
        % use center of gravity
        centroiding = true;
        % use matched filter
        matchedFilter = false;
        % use correlation
        correlation = false;
        % timer
        paceMaker;
        % slopes display handle
        slopesDisplayHandle;
        % slope listener
        slopesListener;
        % intensity display handle
        intensityDisplayHandle;
        % intensity listener
        intensityListener;
        % frame pixel threshold
        framePixelThreshold = -inf;
        % slopes units (default:1 is pixel)
        slopesUnits = 1;
        % zernike to slopes conversion matrix
        zern2slopes;
        % wavefront sensor tag
        tag = 'SHACK-HARTMANN';
    end
    
    properties (SetObservable=true)
        % measurements
        slopes;
    end
    
    properties (Dependent)
        % valid lenslet mask
        validLenslet;
        % measurements reference
        referenceSlopes;
    end
    
    properties (Dependent, SetAccess=private)
        % number of valid lenslet
        nValidLenslet;
        % number of slopes
        nSlope;
        % intensity in each lenslet
        lensletIntensity;
        % valid actuatord
        validActuator;
        % zernike coefficients
        zernCoefs;
    end
    
    properties (Access=private)
%         p_slopes;
        p_referenceSlopes;
        p_validLenslet;
        % index array to reshape a detector frame into a matrix with one
        % raster imagelet per column
        indexRasterLenslet = NaN;
        % lenslet centers
        lensletCenterX;
        lensletCenterY;
        log;
    end
    
    methods
        
        %% Constructor
        function obj = shackHartmann(nLenslet,detectorResolution,minLightRatio)
            error(nargchk(1, 4, nargin))
            obj.lenslets = lensletArray(nLenslet);
            obj.camera   = detector(detectorResolution);
            obj.lenslets.nLensletWavePx = ...
                detectorResolution/nLenslet;
            if nargin>2
                obj.lenslets.minLightRatio = minLightRatio;
            else
                obj.lenslets.minLightRatio = 0;
            end
            obj.validLenslet = true(nLenslet);
            obj.camera.frameGrabber ...
                = obj.lenslets;
            obj.referenceSlopes = zeros(obj.nValidLenslet*2,1);
            obj.p_referenceSlopes = ...
                repmat(obj.p_referenceSlopes,obj.lenslets.nArray,1);
            % Slopes listener
            obj.slopesListener = addlistener(obj,'slopes','PostSet',...
                @(src,evnt) obj.slopesDisplay );
            obj.slopesListener.Enabled = false;
%             % intensity listener (BROKEN: shackhartmann is not deleted after a clear)
%             obj.intensityListener = addlistener(obj.camera,'frame','PostSet',...
%                 @(src,evnt) intensityDisplay(obj) );
% %             obj.intensityListener.Enabled = false;
            % Timer settings
            obj.paceMaker = timer;
            obj.paceMaker.name = 'Shack-Hartmann Wavefront Sensor';
%             obj.paceMaker.TimerFcn = {@timerCallBack, obj};(BROKEN: shackhartmann is not deleted after a clear)
            obj.paceMaker.ExecutionMode = 'FixedSpacing';
            obj.paceMaker.BusyMode = 'drop';
            obj.paceMaker.Period = 1e-1;
            obj.paceMaker.ErrorFcn = 'disp('' @detector: frame rate too high!'')';
            obj.log = logBook.checkIn(obj);
%             function timerCallBack( timerObj, event, a)
%                 %                 fprintf(' @detector: %3.2fs\n',timerObj.instantPeriod)
%                 a.grabAndProcess
%             end
        end
        
        %% Destructor
        function delete(obj)
%             if isvalid(obj.slopesListener)
%                 delete(obj.slopesListener)
%             end
%             if isvalid(obj.intensityListener)
%                 delete(obj.intensityListener)
%             end
%             if isvalid(obj.paceMaker)
%                 if strcmp(obj.paceMaker.Running,'on')
%                     stop(obj.paceMaker)
%                 end
%                 delete(obj.paceMaker)
%             end
            if ishandle(obj.slopesDisplayHandle)
                delete(obj.slopesDisplayHandle)
            end
            if ishandle(obj.intensityDisplayHandle)
                delete(obj.intensityDisplayHandle)
            end
            delete(obj.lenslets)
            delete(obj.camera)
            checkOut(obj.log,obj)
        end
        
        function display(obj)
            %% DISPLAY Display object information
            %
            % display(obj) prints information about the Shack-Hartmann
            % wavefront sensor object
          
            fprintf('___ %s ___\n',obj.tag)
            fprintf(' Shack-Hartmann wavefront sensor: \n  . %d lenslets total on the pupil\n  . %d pixels per lenslet \n',...
                obj.nValidLenslet,obj.camera.resolution(1)/obj.lenslets.nLenslet)
            if isinf(obj.framePixelThreshold)
                algoProp = ', no thresholding!';
            else
                algoProp = sprintf(', pixel threshold: %d\n',obj.framePixelThreshold);
            end
            
            algo = {'quadCell','centroiding','matchedFilter','correlation'};
            algoTF = [obj.quadCell,obj.centroiding,obj.matchedFilter,obj.correlation];
            fprintf('  . spot algorithm: %s%s\n',algo{algoTF},algoProp);
            fprintf('----------------------------------------------------\n')
            display(obj.lenslets)
            display(obj.camera)

        end
        
%         %% Get and Set slopes
%         function slopes = get.slopes(obj)
%             slopes = obj.p_slopes;
%         end
%         function set.slopes(obj,val)
%             obj.p_slopes = val;
%         end
        
        %% Get and Set valid lenslets
        function validLenslet = get.validLenslet(obj)
            validLenslet = obj.p_validLenslet;
        end
        function set.validLenslet(obj,val)
            obj.p_validLenslet = val;
            obj.referenceSlopes(~[obj.validLenslet(:);obj.validLenslet(:)]) = [];
        end
        
        %% Get number of valid lenslet
        function nValidLenslet = get.nValidLenslet(obj)
            nValidLenslet = sum(obj.validLenslet(:));
        end
        
        %% Get number of slopes
        function nSlope = get.nSlope(obj)
            nSlope = obj.nValidLenslet*2;
        end
        
        %% Get valid actuators
        function val = get.validActuator(obj)
            nElements            = 2*obj.lenslets.nLenslet+1; % Linear number of lenslet+actuator
            validLensletActuator = zeros(nElements);
            index                = 2:2:nElements; % Lenslet index
            validLensletActuator(index,index) = obj.validLenslet;
            for xLenslet = index
                for yLenslet = index
                    if validLensletActuator(xLenslet,yLenslet)==1
                        xActuatorIndice = [xLenslet-1,xLenslet-1,...
                            xLenslet+1,xLenslet+1];
                        yActuatorIndice = [yLenslet-1,yLenslet+1,...
                            yLenslet+1,yLenslet-1];
                        validLensletActuator(xActuatorIndice,yActuatorIndice) = 1;
                    end
                end
            end
            index = 1:2:nElements; % Actuator index
            val   = logical(validLensletActuator(index,index));
        end
        
        %% Get/Set the reference spots and update spots location display if
        %% there is one
        function val = get.referenceSlopes(obj)
            val = obj.p_referenceSlopes;
        end
        function set.referenceSlopes(obj,val)
            obj.p_referenceSlopes = val;
%             if ishandle(obj.slopesDisplayHandle)
%                 hc = get(obj.slopesDisplayHandle,'children');
%                 u = obj.p_referenceSlopes(1:end/2)+obj.lensletCenterX;
%                 v = obj.p_referenceSlopes(1+end/2:end)+obj.lensletCenterY;
%                 set(hc(2),'xData',u,'yData',v)
%             end
        end
        
        %% Get the zernike coeficients
        function val = get.zernCoefs(obj)
            val = obj.zern2slopes\obj.slopes;
            val(1,:) = []; % piston=0 removed
        end
        
        %% Computes the intensity in each lenslet
        function lensletIntensity = get.lensletIntensity(obj)
            if isempty(obj.camera.frame)
                lensletIntensity = [];
            else
                [nPx,mPx]  = size(obj.camera.frame);
                nLensletArray = obj.lenslets.nArray;
                nPxLenslet = nPx/obj.lenslets.nLenslet;
                mPxLenslet = mPx/obj.lenslets.nLenslet/nLensletArray;
                try
                    buffer     = obj.camera.frame(obj.indexRasterLenslet);
                catch ME
                    fprintf( '@(shackHartmann)> %s\n',ME.identifier)
                    obj.indexRasterLenslet ...
                        = utilities.rearrange([nPx,mPx],[nPxLenslet,mPxLenslet]);
                    v = ~obj.validLenslet(:);
                    v = repmat(v,nLensletArray,1);
                    obj.indexRasterLenslet(:,v) = [];
                    buffer     = obj.camera.frame(obj.indexRasterLenslet);
                end
                lensletIntensity = sum(buffer);
            end
        end
        
        
        function setValidLenslet(obj,pupilIntensity)
            %% SETVALIDLENSLET Valid lenslet mask
            %
            % setValidLenslet(obj,pupilIntensity) sets the mask of valid
            % lenslet based on the value of minLightRatio in the lenslets
            % object providing the pupil intensity map
            
            if nargin<2
                pupilIntensity = obj.lensletIntensity./max(obj.lensletIntensity);
            else
                n = length(pupilIntensity);
                nL = n/obj.lenslets.nLenslet;
                pupilIntensity = reshape(pupilIntensity,nL,n*obj.lenslets.nLenslet);
                pupilIntensity = sum(pupilIntensity);
                pupilIntensity = reshape(pupilIntensity,obj.lenslets.nLenslet,obj.lenslets.nLenslet*nL);
                pupilIntensity = reshape(pupilIntensity',nL,obj.lenslets.nLenslet^2);
                pupilIntensity = sum(pupilIntensity);
                surfPx         = nL^2;
                pupilIntensity = pupilIntensity/surfPx;
            end
            obj.p_validLenslet  = logical( ...
                reshape( pupilIntensity>=obj.lenslets.minLightRatio , ...
                obj.lenslets.nLenslet,obj.lenslets.nLenslet));
            obj.referenceSlopes = zeros(2*obj.nValidLenslet,1);
            obj.p_referenceSlopes = ...
                repmat(obj.p_referenceSlopes,obj.lenslets.nArray,1);
        end

        
        function varargout = dataProcessing(obj)
            %% DATAPROCESSING Processing a SH-WFS detector frame
            %
            % dataProcessing(obj) computes the WFS slopes
            %
            % out = dataProcessing(obj) computes and returns the WFS slopes
            
            [nPx,mPx,nFrame]  = size(obj.camera.frame);
            nLensletArray = obj.lenslets.nArray;
            nPxLenslet = nPx/obj.lenslets.nLenslet;
            mPxLenslet = mPx/obj.lenslets.nLenslet/nLensletArray;
            if numel(obj.indexRasterLenslet)~=(nPxLenslet*mPxLenslet*obj.nValidLenslet*nLensletArray*nFrame)
                %             try
                % %                 u = obj.indexRasterLenslet;
                % %                 if nFrame>1
                % %                     u = repmat(u,[1,1,nFrame]);
                % %                 end
                %                 buffer     = obj.camera.frame(obj.indexRasterLenslet);
                %             catch ME
                fprintf( '@(shackHartmann)> Setting the raster index \n')
                % get lenslet index
                obj.indexRasterLenslet ...
                    = utilities.rearrange([nPx,mPx/nLensletArray,nLensletArray*nFrame],[nPxLenslet,mPxLenslet]);
                % remove index from non-valid lenslets
                v = ~obj.validLenslet(:);
                v = repmat(v,nLensletArray,1);
                v = repmat(v,nFrame,1);
                obj.indexRasterLenslet(:,v) = [];
                %                 u = obj.indexRasterLenslet;
                %                 if nFrame>1
                %                     u = repmat(u,[1,1,nFrame]);
                %                 end
            end
            % Buffer pre-processing
            buffer     = obj.camera.frame(obj.indexRasterLenslet);
            buffer = (buffer - obj.flatField)./obj.pixelGains;
            % Thresholding
            if isfinite(obj.framePixelThreshold)
                buffer           = buffer - obj.framePixelThreshold;
                buffer(buffer<0) = 0;
            end
            % Centroiding
            if obj.quadCell
            elseif obj.centroiding
                massLenslet         = sum(buffer);
                %                 massLenslet(~index) = [];
                %                 buffer(:,~index)    = [];
                %                 size(buffer)
                [x,y]               = ...
                    meshgrid((0:(nPxLenslet-1)),(0:(mPxLenslet-1)));
                %                 xyBuffer  ...
                %                     = zeros(2*obj.nValidLenslet,1);
                xBuffer             = bsxfun( @times , buffer , x(:) )  ;
                xBuffer             = sum( xBuffer ) ./ massLenslet  ;
%                 xBuffer             = squeeze((xBuffer));
                yBuffer             = bsxfun( @times , buffer , y(:) )  ;
                yBuffer             = sum( yBuffer ) ./ massLenslet  ;
%                 yBuffer             = squeeze((yBuffer));
%                 xyBuffer = squeeze([xBuffer  yBuffer]);
%                 size(xyBuffer)
                xBuffer = reshape(xBuffer,obj.nValidLenslet,nLensletArray*nFrame);
                yBuffer = reshape(yBuffer,obj.nValidLenslet,nLensletArray*nFrame);
                sBuffer = bsxfun(@minus,[xBuffer ; yBuffer],obj.referenceSlopes).*obj.slopesUnits;
                index = isnan(sBuffer);
                if any(index(:)) % if all pixels threshold
                    warning('OOMAO:shackHartmann:dataProcessing',...
                        'Threshold (%f) is probably too high or simply there is no light on some of the lenslets',obj.framePixelThreshold)
                    if ~isempty(obj.slopes)
                        sBuffer(index) = obj.slopes(index);
                    end
                end
                obj.slopes = sBuffer;
            elseif obj.matchedFilter
            elseif obj.correlation
            end
            if nargout>0
                varargout{1} = obj.slopes;
            end
        end
        
        function zern = getZernike(obj,radialOrder)
            zern = zernike(1:zernike.nModeFromRadialOrder(radialOrder),...
                'resolution',obj.lenslets.nLenslet,...
                'pupil',double(obj.validLenslet));
            dzdxy = [zern.xDerivative(obj.validLenslet,:);zern.yDerivative(obj.validLenslet,:)];
            zern.c = dzdxy\obj.slopes;
%             zern.c = dzdxy'*obj.slopes;
        end
        
        function varargout = grabAndProcess(obj)
            %% GRABANDPROCESS Frame grabbing and processing
            %
            % grabAndProcess(obj) grabs a frame and computes the slopes
            %
            % out = grabAndProcess(obj) grabs a frame, computes and returns
            % the slopes
            
            warning('OOMAO;shackHartmann:grabAndProcess',...
                'DEPRECATED! Instead use the uplus operator (+obj)')
            grab(obj.camera)
            dataProcessing(obj);
            if nargout>0
                varargout{1} = obj.slopes;
            end
        end
        function varargout = uplus(obj)
            %% UPLUS + Update operator
            %
            % +obj grabs a frame and computes the slopes
            %
            % obj = +obj returns the shackHartmann object
            
            grab(obj.camera)
            dataProcessing(obj);
            if nargout>0
                varargout{1} = obj;
            end
        end
  
        function relay(obj,src)
            %% RELAY shackhartmann to source relay
            %
            % relay(obj,src) propagates the source through the
            % Shack-Hartmann lenslet array, grab a frame from the detector
            % adding noise if any and process the frame to get the
            % wavefront slopes
            
            propagateThrough(obj.lenslets,src)
%             grabAndProcess(obj)
            grab(obj.camera)
            dataProcessing(obj);
        end
        
        function varargout = slopesDisplay(obj,varargin)
            %% SLOPESDISPLAY WFS slopes display
            %
            % slopesDisplay(obj) displays quiver plot of the slopes
            %
            % slopesDisplay(obj,'PropertyName',PropertyValue) displays
            % quiver plot of the slopes and set the properties of the
            % graphics object quiver
            %
            % h = slopesDisplay(obj,...) returns the graphics handle
            
            if ishandle(obj.slopesDisplayHandle)
                if nargin>1
                    set(obj.slopesDisplayHandle,varargin{:})
                end
                hc = get(obj.slopesDisplayHandle,'children');
                u = obj.referenceSlopes(1:end/2)+...
                    obj.slopes(1:end/2)+obj.lensletCenterX;
                v = obj.referenceSlopes(1+end/2:end)+...
                    obj.slopes(1+end/2:end)+obj.lensletCenterY;
                set(hc(1),'xData',u,'yData',v)
            else
                obj.slopesDisplayHandle = hgtransform(varargin{:});
                [nPx,mPx]  = size(obj.camera.frame);
                nLensletArray = obj.lenslets.nArray;
                nPxLenslet = nPx/obj.lenslets.nLenslet;
                mPxLenslet = mPx/obj.lenslets.nLenslet/nLensletArray;
                % Display lenslet center with a cross
                u = (0:obj.lenslets.nLenslet-1)*(nPxLenslet-1);%(1:nPxLenslet-1:nPx-1)-1
                v = (0:(obj.lenslets.nLenslet-1)*nLensletArray)*(mPxLenslet-1);%(1:mPxLenslet-1:mPx-1)-1
                [obj.lensletCenterX,obj.lensletCenterY] = meshgrid(u,v);
                obj.lensletCenterX = obj.lensletCenterX(obj.validLenslet(:));
                obj.lensletCenterY = obj.lensletCenterY(obj.validLenslet(:));
                if nLensletArray>1
                    offset = (0:nLensletArray-1).*nPx;
                    obj.lensletCenterX = repmat(obj.lensletCenterX,1,nLensletArray);
                    obj.lensletCenterX = bsxfun(@plus,obj.lensletCenterX,offset);
                    obj.lensletCenterX = obj.lensletCenterX(:);
                    obj.lensletCenterY = repmat(obj.lensletCenterY,nLensletArray,1);
                end
                line(obj.lensletCenterX + (nPxLenslet-1)/2,...
                    obj.lensletCenterY + (mPxLenslet-1)/2,...
                    'color','k','Marker','.',...
                    'linestyle','none',...
                    'parent',obj.slopesDisplayHandle)
                axis equal tight
                % Display lenslet footprint
                if obj.lenslets.nLenslet>1
                    lc = ones(1,3)*0.75;
                    u = (0:obj.lenslets.nLenslet-1)*(nPxLenslet-1);
                    kLenslet = 1;
                    v = u(obj.validLenslet(:,kLenslet));
                    prev_v = v;
                    v = [v v(end)+nPxLenslet-1];
                    while length(v)>=length(prev_v)
                        w = ones(1+sum(obj.validLenslet(:,kLenslet)),1)*(kLenslet-1)*(nPxLenslet-1);
                        line(v,w,'LineStyle','-','color',lc)
                        line(w,v,'LineStyle','-','color',lc)
                        prev_v = v;
                        kLenslet = kLenslet + 1;
                        v = u(obj.validLenslet(:,kLenslet));
                        v = [v v(end)+nPxLenslet-1];
                    end
                    w = ones(1+sum(obj.validLenslet(:,kLenslet-1)),1)*(kLenslet-1)*(nPxLenslet-1);
                    line(prev_v,w,'LineStyle','-','color',lc)
                    line(w,prev_v,'LineStyle','-','color',lc)
                    while kLenslet<=obj.lenslets.nLenslet
                        v = u(obj.validLenslet(:,kLenslet));
                        v = [v v(end)+nPxLenslet-1];
                        w = ones(1+sum(obj.validLenslet(:,kLenslet)),1)*kLenslet*(nPxLenslet-1);
                        line(v,w,'LineStyle','-','color',lc)
                        line(w,v,'LineStyle','-','color',lc)
                        kLenslet = kLenslet + 1;
                    end
                end
                % Display slopes reference
                u = obj.referenceSlopes(1:end/2)+obj.lensletCenterX;
                v = obj.referenceSlopes(1+end/2:end)+obj.lensletCenterY;
                line(u,v,'color','b','marker','x',...
                    'linestyle','none',...
                    'parent',obj.slopesDisplayHandle)
                % Display slopes
                u = obj.referenceSlopes(1:end/2)+...
                    obj.slopes(1:end/2)+obj.lensletCenterX;
                v = obj.referenceSlopes(1+end/2:end)+...
                    obj.slopes(1+end/2:end)+obj.lensletCenterY;
                line(u,v,'color','r','marker','+',...
                    'linestyle','none',...
                    'parent',obj.slopesDisplayHandle)
                set(gca,'xlim',[0,obj.lenslets.nLenslet*(nPxLenslet-1)],...
                    'ylim',[0,obj.lenslets.nLenslet*(mPxLenslet-1)],'visible','off')
            end
            if nargout>0
                varargout{1} = obj.slopesDisplayHandle;
            end
        end
        
        function varargout = intensityDisplay(obj,varargin)
            %% INTENSITYDISPLAY WFS lenslet intensity display
            %
            % intensityDisplay(obj) displays the intensity of the lenslets
            %
            % intensityDisplay(obj,'PropertyName',PropertyValue) displays
            % the intensity of the lenslets and set the properties of the
            % graphics object imagesc
            %
            % h = intensityDisplay(obj,...) returns the graphics handle
            %
            % See also: imagesc
            
            intensity = zeros(obj.lenslets.nLenslet,obj.lenslets.nLenslet*obj.lenslets.nArray);
            v = obj.validLenslet(:);
            v = repmat(v,obj.lenslets.nArray,1);
            intensity(v) = obj.lensletIntensity;
            if ishandle(obj.intensityDisplayHandle)
                set(obj.intensityDisplayHandle,...
                    'Cdata',intensity,varargin{:})
            else
                obj.intensityDisplayHandle = imagesc(intensity,varargin{:});
                axis equal tight xy
%                 set(gca,'Clim',[floor(min(intensity(v))),max(intensity(v))])
                colorbar
            end
            if nargout>0
                varargout{1} = obj.intensityDisplayHandle;
            end
        end
        
        function slopesAndFrameDisplay(obj,varargin)
            imagesc(obj.camera,varargin{:});
            slopesDisplay(obj,'matrix',...
                makehgtform('translate',[1,1,0]),varargin{:});
%             if isinf(obj.framePixelThreshold)
%                 clim = get(gca,'clim');
%                 set(gca,'clim',[obj.framePixelThreshold,clim(2)])
%             end
                
        end
        
        function slopesAndIntensityDisplay(obj,varargin)
            intensityDisplay(obj,varargin{:});
            n  = obj.lenslets.nLensletImagePx;
            slopesDisplay(obj,'matrix',...
                makehgtform('translate',-[(n-1)/2,(n-1)/2,0]/n,'scale',1/n,'translate',[1,1,0]*2),varargin{:});
        end
        
        
        function varargout = sparseGradientMatrix(obj)
            %% SPARSEGRADIENTMATRIX
            %
            % Gamma = sparseGradientMatrix(obj)
            %
            % [Gamma,gridMask] = sparseGradientMatrix(obj)
            
            nLenslet = obj.lenslets.nLenslet;
            nMap     = 2*nLenslet+1;
            nValidLenslet ...
                     = obj.nValidLenslet;
            
            i0x = [1:3 1:3]; % x stencil row subscript
            j0x = [ones(1,3) ones(1,3)*3]; % x stencil col subscript
            i0y = [1 3 1 3 1 3]; % y stencil row subscript
            j0y = [1 1 2 2 3 3]; % y stencil col subscript
%             s0x = [-1 -2 -1  1 2  1]/2; % x stencil weight
%             s0y = -[ 1 -1  2 -2 1 -1]/2; % y stencil weight
            s0x = [-1 -1 -1  1 1  1]/3; % x stencil weight
            s0y = -[ 1 -1  1 -1 1 -1]/3; % y stencil weight
            
            i_x = zeros(1,6*nValidLenslet);
            j_x = zeros(1,6*nValidLenslet);
            s_x = zeros(1,6*nValidLenslet);
            i_y = zeros(1,6*nValidLenslet);
            j_y = zeros(1,6*nValidLenslet);
            s_y = zeros(1,6*nValidLenslet);
            
            [iMap0,jMap0] = ndgrid(1:3);
            gridMask = false(nMap);
            
            u   = 1:6;
            
            % Accumulation of x and y stencil row and col subscript and weight
            for jLenslet = 1:nLenslet
                jOffset = 2*(jLenslet-1);
                for iLenslet = 1:nLenslet
                    
                    if obj.validLenslet(iLenslet,jLenslet)
                        
                        iOffset= 2*(iLenslet-1);
                        i_x(u) = i0x + iOffset;
                        j_x(u) = j0x + jOffset;
                        s_x(u) = s0x;
                        i_y(u) = i0y + iOffset;
                        j_y(u) = j0y + jOffset;
                        s_y(u) = s0y;
                        u = u + 6;
                        
                        gridMask( iMap0 + iOffset , jMap0 + jOffset ) = true;
                        
                    end
                    
                end
            end
            indx = sub2ind([nMap,nMap],i_x,j_x); % mapping the x stencil subscript into location index on the phase map
            indy = sub2ind([nMap,nMap],i_y,j_y); % mapping the y stencil subscript into location index on the phase map
            % row index of non zero values in the gradient matrix
            v = 1:2*nValidLenslet;
            v = v(ones(6,1),:);
            % sparse gradient matrix
            Gamma = sparse(v,[indx,indy],[s_x,s_y],2*nValidLenslet,nMap^2);
            Gamma(:,~gridMask) = [];
            
            varargout{1} = Gamma;
            if nargout>1
                varargout{2} = gridMask;
            end
            
        end
        
        function gridMask = validLensletSamplingMask(obj,sample)
            %% VALIDLENSLETSAMPLINGMASK
            %
            % mask = validLensletSamplingMask(obj)
            
            nLenslet = obj.lenslets.nLenslet;
            nMap     = (sample-1)*nLenslet+1;
            
            [iMap0,jMap0] = ndgrid(1:sample);
            gridMask = false(nMap);
            
            % Accumulation of x and y stencil row and col subscript and weight
            for jLenslet = 1:nLenslet
                jOffset = (sample-1)*(jLenslet-1);
                for iLenslet = 1:nLenslet
                    
                    if obj.validLenslet(iLenslet,jLenslet)
                        
                        iOffset= (sample-1)*(iLenslet-1);
                        
                        gridMask( iMap0 + iOffset , jMap0 + jOffset ) = true;
                        
                    end
                    
                end
            end
            
        end

    end
    
end
