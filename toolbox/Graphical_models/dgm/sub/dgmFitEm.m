function [dgm, loglikHist] = dgmFitEm(dgm, data, varargin)
%% Fit a dgm with partially observed data via EM
%
%%
[localEv, precomputeJtree, EMargs] = process_options(varargin, ...
    'localev'         , [] , ...
    'precomputeJtree' , true);
estepFn           = @(dgm, data)estep(dgm, data, localEv);
[dgm, loglikHist] = emAlgo(dgm, data, @init, estepFn, @mstep, EMargs{:});
dgm               = dgmRebuildJtree(dgm, precomputeJtree);

end

function dgm = init(dgm, data, restartNum)
%% Initialize
dgm = removeFields(dgm, 'jtree', 'factors'); 
% use current params for the first run
if restartNum > 1
    dgm.CPDs      = cellfuncell(@(c)c.rndInitFn(c), dgm.CPDs); 
    dgm.localCPDs = cellfuncell(@(c)c.rndInitFn(c), dgm.localCPDs); 
end
end

function [ess, loglik] = estep(dgm, data, localEv)
%% Compute the expected sufficient statistics
localCPDs        = dgm.localCPDs; 
CPDpointers      = dgm.CPDpointers;
localCPDpointers = dgm.localCPDpointers;
nnodes           = dgm.nnodes;
localEqClasses   = computeEquivClasses(localCPDpointers);
nLocalEqClasses  = numel(localEqClasses); 
nDataCases       = size(data, 1); 
nLocalEvCases    = size(localEv, 1); 
nEqClasses       = numel(dgm.CPDs);
ncases           = max(nDataCases, nLocalEvCases); 
counts           = repmat({0}, 1, nEqClasses); 
localWeights     = cell(nLocalEqClasses, 1);
%% preallocate localWeights
for k = 1:nLocalEqClasses
   eqClass         = localEqClasses{k}; 
   N               = nLocalEvCases*numel(eqClass); 
   ns              = localCPDs{eqClass(1)}.nstates;
   localWeights{k} = zeros(N, ns);   
end
lwCounter = ones(1, nLocalEqClasses); 
loglik    = 0;
for i = 1:ncases
    args = {'clamped', [], 'localev', []}; 
    if i <= nDataCases   ,  args{2} = data(i, :);                       end
    if i <= nLocalEvCases,  args{4} = squeezePMTK(localEv(i, :, :));    end
    [fmarg, llobs, pmarg] = dgmInferFamily(dgm, args{:}); % pmarg are the marg probs of the parents with localCPDs
    loglik                = loglik + llobs;
    for j = 1:nnodes
        k = CPDpointers(j); % update the kth bank of parameters
        counts{k} = counts{k} + fmarg{j}.T(:);
        if nLocalEvCases
            l = localCPDpointers(j);  
            if l==0, continue; end    % no localCPD for parent j
            localParent = pmarg{j};   % weights for the lth bank of local params
            localWeights{l}(lwCounter(l), :) = rowvec(localParent.T); 
            lwCounter(l) = lwCounter(l) + 1; 
        end
    end
end
ess.counts       = counts;
ess.emissionEss  = estepEmission(dgm, localEv, localWeights); 
loglik           = loglik + dgmLogPrior(dgm);  % includes localCPDs
end

function emissionEss = estepEmission(dgm, localEv, localWeights)
%% Compute the expcected sufficient statistics for the localCPDs
localCPDs        = dgm.localCPDs; 
nLocalCpds       = numel(localCPDs);
emissionEss      = cell(nLocalCpds, 1);
localCPDpointers = dgm.localCPDpointers; 
if nLocalCpds > 0
    for k = 1:numel(localCPDs)
        localCPD       = localCPDs{k};
        eclass         = findEquivClass(localCPDpointers, k);               % combine data cases and weights from the same equivalence classes
        localData      = cell2mat(localEv2HmmObs(localEv(:, :, eclass))')'; % localData is now ncases*numel(eclass)-by-d in correspondence with localWeights
        emissionEss{k} = localCPD.essFn(localCPD, localData, localWeights{k}); 
    end
end
end

function dgm = mstep(dgm, ess)
%% Maximize
counts = ess.counts;
CPDs = dgm.CPDs;
for k = 1:numel(CPDs); 
    CPD = CPDs{k};
    CPD = CPD.fitFnEss(CPD, counts{k});
    CPDs{k} = CPD;
end
dgm.CPDs = CPDs;
%%
emissionEss = ess.emissionEss;
localCPDs   = dgm.localCPDs;
for i = 1:numel(localCPDs)
    localCPD     = localCPDs{i};
    localCPDs{i} = localCPD.fitFnEss(localCPD, emissionEss{i});
end
dgm.localCPDs = localCPDs;
dgm = removeFields(dgm, 'jtree', 'factors'); 

end