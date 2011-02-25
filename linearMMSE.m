classdef linearMMSE < handle
    %% LINEARMMSE Create a linearMMSE object
    %
    % mmse = linearMMSE(sampling,diameter,atmModel,guideStar)
    % mmse = linearMMSE(sampling,diameter,atmModel,guideStar,mmseStar)
    % mmse = linearMMSE(...,'pupil',pupilMask,'unit',unit)
    
    properties
        tag = 'linearMMSE';
        % pupil sampling
        sampling
        % pupil diameter
        diameter
        % pupil mask
        pupil
        % atmosphere mode
        atmModel
        % guide stars
        guideStarListener
        % guide star covariance matrix
        Cxx
        % mmse star covariance matrix
        Coo
        % mmse star / guide star covariance matrix
        Cox
        nGuideStar
        nmmseStar
        % error unit
        unit;
        % Bayesian minimum mean square error        
        Bmse;
        % zonal of modal model
        model;
        % Zernike mode for zonal model
        zernikeMode;
        % zernike / guide star covariance matrix
        Cax
        % zernike / mmse star covariance matrix
        Cao
        % zernike polynomials matrix
        Z
        % zernike covariance matrix
        Caa
        % mmse reconstructor
        mmseBuilder
        % Zernike noise variance
        zernNoiseCovariance
    end
    
    properties (SetObservable=true)
        guideStar
    end
    
    properties (Dependent)
        % mmse estimates directions
        mmseStar
    end
    
    properties (Dependent,SetAccess=private)
        % error variance
        var
        % error rms
        rms
        % error variance map
        varMap
        % error rms map
        rmsMap        
    end
    
    properties (Dependent)
        %  noise covariance
        noiseCovariance
    end
    
    properties (Access=private)
        log
        p_mmseStar
        zernP
        p_noiseCovariance
    end
 
    methods
        
        %% Constructor
        function obj = linearMMSE(sampling,diameter,atmModel,guideStar,varargin)
            
            inputs = inputParser;
            inputs.addRequired('sampling',@isnumeric);
            inputs.addRequired('diameter',@isnumeric);
            inputs.addRequired('atmModel',@(x) isa(x,'atmosphere'));
            inputs.addRequired('guideStar',@(x) isa(x,'source'));
            inputs.addOptional('mmseStar',[],@(x) isa(x,'source'));
            inputs.addParamValue('pupil',true(sampling),@islogical);
            inputs.addParamValue('unit',[],@isnumeric);
            inputs.addParamValue('model','zonal',@ischar);
            inputs.addParamValue('zernikeMode',[],@isnumeric);
            inputs.addParamValue('noiseCovariance',[],@isnumeric);
            
            inputs.parse(sampling,diameter,atmModel,guideStar,varargin{:});
            
            obj.sampling   = inputs.Results.sampling;
            obj.diameter   = inputs.Results.diameter;
            obj.atmModel   = inputs.Results.atmModel;
            obj.guideStar  = inputs.Results.guideStar;
            obj.nGuideStar = length(obj.guideStar);
            obj.p_mmseStar = inputs.Results.mmseStar;    
            obj.nmmseStar  = length(obj.p_mmseStar);
            obj.pupil      = inputs.Results.pupil;   
            obj.unit       = inputs.Results.unit;   
            obj.model      = inputs.Results.model;
            obj.zernikeMode= inputs.Results.zernikeMode;
            obj.noiseCovariance   = inputs.Results.noiseCovariance;
            
            obj.guideStarListener = addlistener(obj,'guideStar','PostSet',@obj.resetGuideStar);
            obj.log = logBook.checkIn(obj);
            
%             add(obj.log,obj,'Computing the covariance matrices')
            
            poolWasAlreadyOpen = true;
            
            switch obj.model
                
                case 'zonal'
                    
                    if matlabpool('size')==0
                        matlabpool('open')
                        poolWasAlreadyOpen = false;
                    end
                    
                    [obj.Cxx,obj.Cox] = ...
                        phaseStats.spatioAngularCovarianceMatrix(...
                        obj.sampling,obj.diameter,...
                        obj.atmModel,obj.guideStar,obj.p_mmseStar,'mask',obj.pupil);
                    obj.Coo = phaseStats.spatioAngularCovarianceMatrix(...
                        obj.sampling,obj.diameter,...
                        obj.atmModel,obj.p_mmseStar(1),'mask',obj.pupil);
            
                    if ~poolWasAlreadyOpen
                        matlabpool('close')
                    end
            
                case 'modal'
                    
                      obj.zernP    = zernike(obj.zernikeMode,obj.diameter,...
                          'resolution',obj.sampling);
                      obj.Cxx = zernikeStats.angularCovarianceAlt(obj.zernP,...
                          obj.atmModel,obj.guideStar,obj.guideStar);            
                      obj.Cox = { zernikeStats.angularCovarianceAlt(obj.zernP,...
                          obj.atmModel,obj.p_mmseStar,obj.guideStar) }; 
%                       obj.Cxx = cell2mat(zernikeStats.angularCovariance(obj.zernP,...
%                           obj.atmModel,obj.guideStar));            
%                       obj.Cox = zernikeStats.angularCovariance(obj.zernP,...
%                           obj.atmModel,obj.guideStar,obj.p_mmseStar)'; 
                      obj.Coo = zernikeStats.covariance(obj.zernP,obj.atmModel);
                    
                otherwise
                    
                    error('oomao:linearMMSE:linearMMSE',...
                        'The model is either zonal or modal')
                    
            end
            
%             add(obj.log,obj,'Computing the mmse builder')
            
            solveMmse(obj);
            
        end
        
        
        %% Destructor
        function delete(obj)
            if ~isempty(obj.log)
                checkOut(obj.log,obj)
            end
        end
        
        %% Set/Get mmseStar
        function set.mmseStar(obj,val)
            obj.p_mmseStar = val;
            add(obj.log,obj,'Computing the mmse/guide stars covariance matrix')
            obj.Cox = phaseStats.spatioAngularCovarianceMatrix(...
                obj.sampling,obj.diameter,...
                obj.atmModel,obj.guideStar,obj.p_mmseStar,'mask',obj.pupil);
            obj.Coo = phaseStats.spatioAngularCovarianceMatrix(...
                obj.sampling,obj.diameter,...
                obj.atmModel,obj.p_mmseStar(1),'mask',obj.pupil);
        end
        function val = get.mmseStar(obj)
            val = obj.p_mmseStar;
        end
        
        %% Set/Get noiseCovariance
        function set.noiseCovariance(obj,val)
            if ~isempty(val)
                if isempty(obj.zernNoiseCovariance)
                    zernTmp = zernike(1:66,obj.diameter);
                    obj.zernNoiseCovariance = zernTmp.noiseCovariance(obj.zernikeMode,obj.zernikeMode);
                end
                obj.nGuideStar = length(val);
                obj.p_noiseCovariance = repmat({obj.zernNoiseCovariance},1,obj.nGuideStar);
                obj.p_noiseCovariance = blkdiag( obj.p_noiseCovariance{:} );
                nMode = length(obj.zernikeMode);
                val = val(:);
                val = repmat( val , 1,  nMode )';
                obj.p_noiseCovariance = diag(val(:));%.*obj.p_noiseCovariance;
                obj.Bmse = [];
            end
        end
        function val = get.noiseCovariance(obj)
            val = obj.p_noiseCovariance;
        end
        
        function lmmse(obj,fieldStar)
            %% LMMSE Linear Minimum Mean Square Error
            
            %             add(obj.log,obj,'Bayesian Minimum Mean Square Error computation in progress...')
            
            if nargin==1
                if isempty(obj.p_noiseCovariance)
                    fun = @(x,y) obj.Coo - y*x';
                else
                    fun = @(x,y) obj.Coo - y*x' + y*obj.p_noiseCovariance*y';
                end
                obj.Bmse = cellfun( fun , obj.Cox , obj.mmseBuilder , 'uniformOutput' , false );
            else
                Co1x = ...
                    phaseStats.spatioAngularCovarianceMatrix(...
                    obj.sampling,obj.diameter,...
                    obj.atmModel,obj.guideStar,fieldStar,'mask',obj.pupil);
                fun = @(x) obj.Coo + ...
                    obj.Cox{1}/obj.Cxx*obj.Cox{1}' - ...
                    x/obj.Cxx*obj.Cox{1}' - obj.Cox{1}/obj.Cxx*x';
                obj.Bmse = cellfun( fun , Co1x , 'uniformOutput' , false );
            end
            
        end
       
        function map = get.varMap(obj)
            %% VARMAP Pupil error variance map
            
            if isempty(obj.Bmse)
                lmmse(obj)
            end
%             add(obj.log,obj,'Pupil error variance map computation in progress...')
            out = cellfun( @diag , obj.Bmse' , 'uniformOutput', false );
            out = cell2mat(out);
            map = zeros(obj.sampling,obj.sampling*obj.nmmseStar);
            mask = repmat( obj.pupil, 1 , obj.nmmseStar);
            map(mask) = out;
                
        end
       
        function out = get.var(obj)
            %% VAR Pupil error variance
            
            if isempty(obj.Bmse)
                lmmse(obj)
            end
%             add(obj.log,obj,'Pupil error variance computation in progress...')
            if iscell(obj.Bmse)
                out = cellfun( @trace , obj.Bmse , 'uniformOutput', true );
            else
                out = trace(obj.Bmse);
            end
            if strcmp(obj.model,'zonal')
                out = out/sum(obj.pupil(:));
            end
        end
        
        function map = get.rmsMap(obj)
            %% RMSMAP Pupil error rms map
            
            map = opd(obj,obj.varMap);
        end
        
        function out = get.rms(obj)
            %% RMS Pupil error rms
            
            out = opd(obj,obj.var);
        end        

    end
       
    
    methods (Access=private)
        
        function out = opd(obj,val)
            %% OPD Phase to opd conversion
            
            out = sqrt(val);
            if ~isempty(obj.unit)
                add(obj.log,obj,sprintf('Rms in 1E%d meter',obj.unit))
                out = 10^-obj.unit*...
                    out*obj.atmModel.wavelength/(2*pi);
            end
        end
        
        function resetGuideStar(obj,varargin) % obj, src, event
            %% RESETGUIDESTAR
            
%             fprintf(' Resetting Cxx\n')
            switch obj.model
                
                case 'zonal'
                    
                    [obj.Cxx,obj.Cox] = ...
                        phaseStats.spatioAngularCovarianceMatrix(...
                        obj.sampling,obj.diameter,...
                        obj.atmModel,obj.guideStar,obj.p_mmseStar,'mask',obj.pupil);
                    
                case 'modal'
                    
                    obj.Cxx = zernikeStats.angularCovarianceAlt(obj.zernP,...
                        obj.atmModel,obj.guideStar,obj.guideStar);
                    obj.Cox = { zernikeStats.angularCovarianceAlt(obj.zernP,...
                        obj.atmModel,obj.p_mmseStar,obj.guideStar) };
                    
            end
            
            solveMmse(obj);
            obj.Bmse = [];
            
        end
        
        function solveMmse(obj)
            %% SOLVEMMSE
            
            m_mmseBuilder = cell(obj.nmmseStar,1);
            m_Cox = obj.Cox;
            m_Cxx = obj.Cxx;
            parfor k=1:obj.nmmseStar
                m_mmseBuilder{k} = m_Cox{k}/m_Cxx;
            end
            obj.mmseBuilder = m_mmseBuilder;

        end
        
    end
    
    methods (Static)
        
        function varargin = demoModal
            %% DEMOZONAL
            
            D = 10;
            n = 21;
            band = photometry.V;
            atm = atmosphere(photometry.V,0.15,60,'altitude',10e3);
            atm.wavelength = band;
%             gs = source('asterism',{[1,arcsec(60),0]},'wavelength',band);
            ss  = source('wavelength',band);
            pause(5)
            
%             mmse = linearMMSE(32,10,atm,gs,ss,...
%                 'model','modal','zernikeMode',2:3,...
%                 'unit',-9);
            zern = zernike(2:3,D,'resolution',n);
            %ZP = zern.p(zern.pupilLogical,:);
            
            gsRadius = 5:5:60;
            mmseTTRms = zeros(length(gsRadius),2);
            aniso   = zeros(1,length(gsRadius));
            m_log = logBook.checkIn();
            m_log.verbose = false;
            for k=1:length(gsRadius)
                fprintf(' --> gsRadius = %d arcsec\n', gsRadius(k) )
                gs = source('asterism',{[3,arcsec(gsRadius(k)),0]},'wavelength',band);
                mmseTT = linearMMSE(n,D,atm,gs,ss,...
                    'model','modal','zernikeMode',2:3,...
                    'unit',-9);
                mmseZonal = linearMMSE(n,D,atm,gs,ss,...
                    'pupil',zern.pupilLogical,'unit',-9);
                lmmse(mmseZonal)
                mmseTTRms(k,1) = mmseTT.rms;
                mmseTTRms(k,2) = mmseZonal.rms;%1e9*sqrt(trace(ZP'*mmseZonal.Bmse{1}*ZP))./ss.waveNumber;
                aniso(k) = zernikeStats.anisokinetism(zern,atm,gs(1),-9);
            end
            m_log.verbose = true;e
            
            figure
            plot(gsRadius,mmseTTRms,'.-',gsRadius,aniso,'.-')
            xlabel('GS radius [arcsec]')
            ylabel('WFE [nm]')
            legend('TT Stars','NGS Stars','TT anisok.')
            
            varargin = {atm, zern, mmseTT, mmseZonal};
            
        end
        
    end
    
end