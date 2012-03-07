classdef gpuSource < source
    
    methods
        
        function obj = gpuSource(varargin)
            obj = obj@source(varargin{:});
            set(obj,'tag','GPU SOURCE');
        end
        
        function obj = mtimes(obj,otherObj)
            %% * Source object propagation operator
            %
            % src = src*otherObj propagate src through otherObj
            % multiplying the source amplitude by the otherObj transmitance
            % and adding the otherObj phase to the source phase
            
            nObj = numel(obj);
            for kObj = 1:nObj
                obj(kObj).opticalPath{ length(obj(kObj).opticalPath)+1 } = otherObj;
            end
            %             relay(otherObj,obj);
            fprintf(' *!* +source *!*\n')
        end
        
        function uplus(obj)
            %% UPLUS Source update/stream operator
            %
            % +obj streams the source object through its optical path
            
            nObj = numel(obj);
            for kObj = 1:nObj
                obj(kObj).mask        = [];
                obj(kObj).p_amplitude = 1;
                obj(kObj).p_phase     = 0;
            end
            %             cellfun(@(x)relay(x,obj),obj(1).opticalPath,'uniformOutput',false)
            gpuRun(obj)
        end
        
        function obj = times(obj,otherObj)
            %% .* Source object reset and propagation operator
            %
            % src = src.*otherObj propagates src through otherObj setting the
            % source amplitude to the otherObj transmitance and the source
            % phase to the otherObj phase
            
            mtimes(reset(obj),otherObj);
        end
        
    end
    
    methods (Access=private)
        
        function gpuRun(obj)
            
            nDevice = length( obj(1).opticalPath );
            nObj = size(obj,2);
            xL = zeros(nObj,1);
            yL = zeros(nObj,1);
            for kObj = 1:nObj
                xL(kObj) = obj(1,kObj,1).viewPoint(1);
                yL(kObj) = obj(1,kObj,1).viewPoint(2);
            end
            fr = cat(3,obj.extent);
            dmPhase = [];
            for kDevice = 1:nDevice
                deviceClass = class(obj(1).opticalPath{kDevice});
                switch deviceClass
                    case {'telescope','giantMagellanTelescope'}
                        tel = obj(1).opticalPath{kDevice};
                        %                         relayGpuSource(tel,obj)
                        set(obj,'mask',tel.pupilLogical)
                    case 'deformableMirror'
                        dm = obj(1).opticalPath{kDevice};
                        relay(dm,obj)
                        dmPhase = obj.phase;
                    case 'shackHartmann'
                        wfs = obj(1).opticalPath{kDevice};
                        nLenslet      = wfs.lenslets.nLenslet;
                        nValidLenslet = wfs.nValidLenslet;
                        nPixelLenslet = wfs.lenslets.nLensletWavePx;
                        nLensletImagePx = wfs.lenslets.nLensletImagePx;
                        nArray         = max( size(obj,2) , size(dmPhase,3) );
                        wfs.lenslets.nArray = nArray;
                        nLenslet2      = nLenslet^2;
                        nLenslets      = nLenslet^2*nArray;
                        nValidLenslets = nValidLenslet*nArray;
                        nLensletWavePx = nPixelLenslet;
                        nOutWavePx     = 2*nLensletWavePx + rem(nLensletWavePx,2);
                        n1             = nLensletWavePx*nLenslet;
                        n2             = n1*nArray;
                        
                        % phasor to align the spot on the center of the image
                        u = (0:(nLensletWavePx-1)).*(1-nLensletWavePx)./nOutWavePx;
                        phasor = exp(-1i*pi.*u);
                        phasor = phasor.'*phasor;
                        %%
                        index    = tools.rearrange( [n1,n1]  , [nLensletWavePx,nLensletWavePx] );
                        if isinf(tel.samplingTime)
                            error('oomao:gpuSource:gpuRun','Telescope sampling time must be finite!')
                        end
                        pupilWave = tel.pupil.*sqrt(tel.samplingTime*tel.area/tel.pixelArea)/nOutWavePx;
                        pupilWave = reshape( pupilWave(index) , nPixelLenslet,nPixelLenslet,nLenslet2);
                        if isempty(dmPhase)
                            dmPhase = gzeros(1,1,nLenslet2,'single');
                        else
                            fprintf('Reshaping the DM phase from %d.%d.%d to ...',...
                                size(dmPhase,1),size(dmPhase,2),size(dmPhase,3))
                            tId = tic;
                            buf2 = [];
                            for kDmPhase=1:size(dmPhase,3)
                                buf1 = dmPhase(:,:,kDmPhase);
                                buf1 = reshape( buf1(index) , nPixelLenslet,nPixelLenslet,nLenslet2);
                                %                                 buf1(:,:,~wfs.validLenslet) = [];
                                buf2 = cat(3,buf2,buf1);
                            end
                            dmPhase = gsingle(buf2);
                            clear('buf1','buf2')
                            et = toc(tId);
                            fprintf('\b\b\b\b %d.%d.%d: done in %4.2fs\n',...
                                size(dmPhase,1),size(dmPhase,2),size(dmPhase,3),et)
                        end
                        [xPup,yPup] = meshgrid(linspace(-1,1,tel.resolution)*tel.R);
                        yPup     = reshape( yPup(index)     , nPixelLenslet,nPixelLenslet,nLenslet2);
                        xPup     = reshape( xPup(index)     , nPixelLenslet,nPixelLenslet,nLenslet2);
                        buf2     = gzeros(nLensletImagePx,'single');
                        buf3     = gzeros(nLensletImagePx,'single');
                        lensletIndex     = false(nOutWavePx);
%                         lensletIndex(1:nPixelLenslet,1:nPixelLenslet) = false;
                        t_n = nPixelLenslet/2-nLensletImagePx/2 + 1;
                        field = t_n:(t_n+nLensletImagePx-1);
                        lensletIndex(field,field) = true;

                        %%
                        phasor           = gdouble( phasor);
                        pupilWave         = gsingle( pupilWave );
                        pupilWave = bsxfun( @times , pupilWave,phasor);
                        xPup             = gdouble( xPup );
                        yPup             = gdouble( yPup );
                        xL               = gdouble( xL );
                        yL               = gdouble( yL );
                        lensletIndex     = glogical( lensletIndex );
                        nHeight = size(obj,3);
                        if size(fr,3)==1
                            fr = repmat( fr , [1 ,1 ,nHeight] );
                        end
                        fr = gsingle(fr);
                        waveNumber = obj(1).waveNumber;
                        objectiveFocalLength = obj(1).objectiveFocalLength;
                        srcHeight  = gdouble( [obj(1,1,:).height]);
                        kLenslet_ = 1:nLenslets;
                        validLenslet = repmat( wfs.validLenslet(:)' , 1 , nArray );
                        kLenslet_( ~validLenslet ) = [];
                        kLenslet_ = gsingle( kLenslet_ );
                        naProfile = [obj(1,1,:).nPhoton];
                        [yLensletCoordinates,xLensletCoordinates] = ...
                            ndgrid(linspace(-1,1,nLenslet)*tel.R*(1-1/nLenslet));
                        xLensletCoordinates = gsingle(xLensletCoordinates);
                        yLensletCoordinates = gsingle(yLensletCoordinates);
                        %%
                        lensletIntensity = gzeros(nLensletImagePx^2,nValidLenslets,'single');
                        nGpu = ceil(1.5*wfs.nValidLenslet*nOutWavePx^2*nArray*1e-6/135);
                        validLensletMaxStep = floor(nValidLenslets/nGpu);
                        validLensletRange   = 1:validLensletMaxStep;
                        
%                         fieldStop = tools.piston(90,96);
%                         fieldStop = gsingle(fieldStop(:));
                        
                        %%% Setting the function point for the geometric
                        %%% propagator through the atmosphere
                        [nLayer,altitude_m,phase_m,xi,yi,srcDirectionVector,R_m,nPixel,lambdaRatio] = ...
                            atmosphereInit(obj,tel,index,nPixelLenslet,nLenslet2,obj(1).wavelength);
                        if isempty(tel.opticalAberration)
                            % no propagation!
                            pupilPhase = @(nLayer_,altitude_m_,phase_m_,xi_,yi_,srcDirectionVector_,R_m_,nPixel_,nPixelLenslet_,height_) ...
                                atmosphereGeometricPropagatorNull(nLayer_,altitude_m_,phase_m_,xi_,yi_,srcDirectionVector_,R_m_,nPixel_,nPixelLenslet_,height_);
                        else
                            % propagation!
                            fprintf('(with atmosphere ')
                            pupilPhase = @(nLayer_,altitude_m_,phase_m_,xi_,yi_,srcDirectionVector_,R_m_,nPixel_,nPixelLenslet_,height_) ...
                                atmosphereGeometricPropagator(nLayer_,altitude_m_,phase_m_,xi_,yi_,srcDirectionVector_,R_m_,nPixel_,nPixelLenslet_,height_);
                        end
                        
                        %%% Setting the spot convolution function pointer 
                        if isempty(fr)
                            % no convolution!
                            fprintf('but without transverse LGS profile) ')
                            spotsConvolution = @(buf2_ , fr__) spotsConvolveNull(buf2_ , fr__);
                            fr_ = false(1,1,nHeight);
                        else
                            % convolution!
                            spotsConvolution = @(buf2_ , fr__) spotsConvolve(buf2_ , fr__);
                        end
                        
                        %%% Setting the function pointer for the spherical
                        %%% wave propagation
                        if all(isinf([obj.height]))
                            % NGS!
                            pupilProp = @(xPup_,yPup_,xL_,yL_,height_,objectiveFocalLength_,waveNumber_,buf0_) ...
                                pupilPropNgs(xPup_,yPup_,xL_,yL_,height_,objectiveFocalLength_,waveNumber_,buf0_);
                        else
                            % LGS
                            pupilProp = @(xPup_,yPup_,xL_,yL_,height_,objectiveFocalLength_,waveNumber_,buf0_) ...
                                pupilPropLgs(xPup_,yPup_,xL_,yL_,height_,objectiveFocalLength_,waveNumber_,buf0_);
                        end
                        
                        tId = tic;
                        for kGpu=1:nGpu
                            
                            kValidLenslet_ = validLensletRange + (kGpu-1)*validLensletMaxStep;
                            kValidLenslet_(end) = min(kValidLenslet_(end),nValidLenslets);
                            %             gsync
                            fprintf(' -> GPU loop %d/%d: ',kGpu,nGpu)
                            
                            gfor kValidLenslet = kValidLenslet_
                            
                            buf3(:)     = 0;

                            for kHeight = 1:nHeight % src height
                                
                                height          = srcHeight(kHeight);
                                naProfileHeight = naProfile(kHeight);
                                fr_             = fr(:,:,kHeight);
                                
                                kLenslet = kLenslet_(kValidLenslet);
                                n = fix((kLenslet-1)/nLenslet2);
                                k = kLenslet - n*nLenslet2;
                                
                                F = pupilPhase(nLayer,altitude_m,phase_m,xi(:,:,k),yi(:,:,k),srcDirectionVector(:,n+1),R_m,nPixel,nPixelLenslet,height);
                                F = lambdaRatio*F + dmPhase(:,:,k);
                                buf0 = pupilWave(:,:,k).*exp(1i*F);
                                
                                lensletWave = pupilProp(xPup(:,:,k),yPup(:,:,k),xL(n+1),yL(n+1),...
                                    height,objectiveFocalLength,waveNumber,buf0);
                                
                                buf1         = fft2( lensletWave , nOutWavePx , nOutWavePx );
                                buf2(:)      = abs( buf1(lensletIndex) ).^2;
                                buf3         = buf3 + buf2*naProfileHeight;
%                                 buf2         = spotsConvolution( buf2 , fr_);
%                                 lensletIntensity(:,kValidLenslet) = lensletIntensity(:,kValidLenslet) + ...
%                                     buf2(:)*naProfileHeight;
                                
                            end
                            buf3 = spotsConvolution( buf3 , fr_);
                            lensletIntensity(:,kValidLenslet) = buf3(:);
                            
                            gend % gfor ends here!
                            
                            
                        end
                        
                        et = toc(tId);
                        fprintf('elapsed time: %4.2f\n',et)
                        %                         Fd = double(F);
                        %                         save('interpPhase.mat','Fd')
                        %                 geval(lensletIntensity)
                        %                 gsync
                        
                        %%
%                         lensletIntensity = bsxfun( @times , lensletIntensity , fieldStop);

                        n1             = nLensletImagePx*nLenslet;
                        n2             = n1*nArray;
                        imagelets  = zeros(n1,n2);
                        index = tools.rearrange( [n1,n2] , [nLensletImagePx,nLensletImagePx] );
                        imagelets(index(:,validLenslet)) = wfs.lenslets.throughput*double(lensletIntensity(:));
                        wfs.lenslets.imagelets = imagelets;
                        
                        +wfs; %#ok<VUNUS>
                end
                
            end
        end
        
    end
    
end

function [nLayer,altitude_m,phase_m,xi,yi,srcDirectionVector,R_m,nPixel,lambdaRatio] = ...
    atmosphereInit(obj,tel,index,nPixelLenslet,nLenslet2,srcWavelength )
%% initialize atmosphere parameters
atm_m           = tel.opticalAberration;
if isempty(atm_m)
    nLayer = [];
    altitude_m = [];
    phase_m = [];
    R_m = [];
    nPixel = [];
    lambdaRatio = 1;
else
    nLayer          = atm_m.nLayer;
    layers          = atm_m.layer;
    phase_m         = { layers.phase };
    phase_m         = cellfun( @(x) gsingle(x) , phase_m , 'UniformOutput', false);
    altitude_m      = gsingle([layers.altitude]);
    R_m    = gsingle([layers.D]*0.5);
    nPixel = gsingle([layers.nPixel]);
    lambdaRatio = gdouble(atm_m.wavelength/srcWavelength);
end

sampler_m       = gsingle(linspace(-1,1,tel.resolution));
u = sampler_m*tel.R;
[xi,yi] = meshgrid(u);
xi = reshape( xi(index) , nPixelLenslet , nPixelLenslet , nLenslet2 );
yi = reshape( yi(index) , nPixelLenslet , nPixelLenslet , nLenslet2 );
srcDirectionVector  = gsingle([obj(1,:,1).directionVector]);
end

function lensletWave = pupilPropLgs(xPup,yPup,xL,yL,...
    height,objectiveFocalLength,waveNumber,telPupil)
%% lgs propagation (spherical wave)
rho = hypot( xPup - xL , yPup - yL );
s  = hypot(rho,height);
s0 = hypot(rho,objectiveFocalLength);
sphericalPhase = waveNumber*(s - s0);

lensletWave  = telPupil.*exp(1i*sphericalPhase)./height;
end

function lensletWave = pupilPropNgs(~,~,~,~,~,~,~,telPupil)
%% ngs propagation (plane wave)
lensletWave  = telPupil;
end

function F = atmosphereGeometricPropagator(nLayer,altitude_m,phase_m,xi,yi,srcDirectionVector,R_m,nPixel,nPixelLenslet,height)
%% propagation through phase screens
xDvSrc = srcDirectionVector(1);
yDvSrc = srcDirectionVector(2);
F = gzeros(nPixelLenslet,nPixelLenslet,'single');
for kLayer = 1:nLayer
    
    [xs,ys] = meshgrid(R_m(kLayer)*linspace(-1,1,nPixel(kLayer)));
    red = (1-altitude_m(kLayer)./height);
    xc = altitude_m(kLayer).*xDvSrc;
    yc = altitude_m(kLayer).*yDvSrc;
    
    yiLenslet = yi*red + yc;
    xiLenslet = xi*red + xc;
    
    arg3 = phase_m{kLayer};
    
    [nrows,ncols] = size(arg3);
    s = 1 + (xiLenslet-xs(1))/(xs(end)-xs(1))*(ncols-1);
    t = 1 + (yiLenslet-ys(1))/(ys(end)-ys(1))*(nrows-1);
    ndx = floor(t)+floor(s-1)*nrows;
    s(:) = (s - floor(s));
    t(:) = (t - floor(t));
    onemt = 1-t;
    F =  F + ( arg3(ndx).*(onemt) + arg3(ndx+1).*t ).*(1-s) + ...
        ( arg3(ndx+nrows).*(onemt) + arg3(ndx+(nrows+1)).*t ).*s;
    
end

end

function F = atmosphereGeometricPropagatorNull(~,~,~,~,~,~,~,~,nPixelLenslet,~)
%% no propagation through phase screens
F = gzeros(nPixelLenslet,nPixelLenslet,'single');
end

function buf2 = spotsConvolve(buf2 , fr_ )
%% spots convolution
buf2         = conv2( buf2 , fr_ ,'same');
end
function out = spotsConvolveNull(buf2 , ~ )
%% no spots convolution
out         = buf2;
end