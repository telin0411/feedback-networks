------------------------------------------------------------------------
--ConvRNN double for loop
------------------------------------------------------------------------
local _ = require 'moses'
require 'nn'
require 'dpnn'
require 'rnn'
require 'ConvLSTM_bn'
require 'opts'

local ConvRNN, parent = torch.class('nn.ConvRNN_double', 'nn.AbstractRecurrent')

function ConvRNN:__init(inputSize, outputSize, rho, rhoi, kc, km, stride, Kr)
   parent.__init(self, rho or 9999)
   self.rhoi = rhoi
   self.inputSize = inputSize
   self.outputSize = outputSize   
   self.kc = kc
   self.km = km
   self.padc = torch.floor(kc/2)
   self.padm = torch.floor(km/2)
   self.stride = stride or 1
   self.Kr = Kr
   -- build the model
   self.recurrentModule = self:buildModel()
   -- make it work with nn.Container
   self.modules[1] = self.recurrentModule
   self.sharedClones[1] = self.recurrentModule 
   
   -- for output(0), cell(0) and gradCell(T)
   self.zeroTensor = torch.Tensor() 
   
   self.cells = {}
   self.gradCells = {}
   self.stepr = 1
end

-------------------------- factory methods -----------------------------
function ConvRNN:buildModel()
   -- input : {input, prevOutput}
   -- output : {output}
   -- Calculate all four gates in one go : input, hidden
   local T    = self.rhoi
   local D    = 16
   local W    = 32
   local N    = 128
   local nGPU = 1
   self.i = nn.Sequential()
       -- :add(nn.SpatialConvolution(self.inputSize, self.outputSize, self.kc, self.kc, self.stride, self.stride, self.padc, self.padc))
       -- :add(nn.SpatialBatchNormalization(self.outputSize, 1e-3))
       :add(nn.Replicate(T))
       :add(nn.Contiguous())
       :add(nn.View(T, -1, D, W, W))
       :add(nn.SplitTable(1))
       :add(nn.Sequencer(nn.ConvLSTM_bn(self.inputSize,   2*self.inputSize, T, 3, 3, 1, N/nGPU)))
       :add(nn.Sequencer(nn.ConvLSTM_bn(2*self.inputSize, 4*self.inputSize, T, 3, 3, 1, N/nGPU)))
       :add(nn.SelectTable(-1))

   self.o = nn.Sequential()
       -- :add(nn.SpatialConvolution(self.outputSize, self.outputSize, self.km, self.km, 1, 1, self.padm, self.padm))
       -- :add(nn.SpatialBatchNormalization(self.outputSize, 1e-3))
       :add(nn.Replicate(T))
       :add(nn.Contiguous())
       :add(nn.View(T, -1, 4*self.inputSize, 32, 32))
       :add(nn.SplitTable(1))
       :add(nn.Sequencer(nn.ConvLSTM_bn(4*self.inputSize, 4*self.inputSize, T, 3, 3, 1, N/nGPU)))
       :add(nn.Sequencer(nn.ConvLSTM_bn(4*self.inputSize, 4*self.inputSize, T, 3, 3, 1, N/nGPU)))
       :add(nn.SelectTable(-1))
       
   local para = nn.ParallelTable():add(self.i):add(self.o)
   local model = nn.Sequential()
   model:add(para)
   model:add(nn.CAddTable())
   model:add(nn.ReLU(true))
  
   return model
end

------------------------- forward backward -----------------------------
function ConvRNN:updateOutput(input)
   --print(#input)
   local prevOutput
   if self.stepr == 1 then
      prevOutput = self.userPrevOutput or self.zeroTensor
      if input:dim() == 4 then -- batch 
         self.zeroTensor:resize(input:size(1), self.outputSize, self.Kr, self.Kr):zero()
      else
         self.zeroTensor:resize(self.outputSize, self.Kr, self.Kr):zero()
      end
   else
      -- previous output and cell of this module
      prevOutput = self.outputs[self.stepr-1]
   end
   --print(#prevOutput)
   -- output(t) = gru{input(t), output(t-1)}
   print (#input)
   print (#prevOutput)
   local output
   if self.train ~= false then
      self:recycle()
      local recurrentModule = self:getStepModule(self.stepr)
      -- the actual forward propagation
      output = recurrentModule:updateOutput{input, prevOutput}
   else
      output = self.recurrentModule:updateOutput{input, prevOutput}
   end
   self.outputs[self.stepr] = output
   
   self.output = output
   
   self.stepr = self.stepr + 1
   self.gradPrevOutput = nil
   self.updateGradInputStep = nil
   self.accGradParametersStep = nil
   -- note that we don't return the cell, just the output
   return self.output
end

function ConvRNN:_updateGradInput(input, gradOutput)
   assert(self.stepr > 1, "expecting at least one updateOutput")
   local stepr = self.updateGradInputStep - 1
   assert(stepr >= 1)
   
   local gradInput
   -- set the output/gradOutput states of current Module
   local recurrentModule = self:getStepModule(stepr)
   
   -- backward propagate through this stepr
   if self.gradPrevOutput then
      self._gradOutputs[stepr] = nn.rnn.recursiveCopy(self._gradOutputs[stepr], self.gradPrevOutput)
      nn.rnn.recursiveAdd(self._gradOutputs[stepr], gradOutput)
      gradOutput = self._gradOutputs[stepr]
   end
   
   local output = (stepr == 1) and (self.userPrevOutput or self.zeroTensor) or self.outputs[stepr-1]
   local inputTable = {input, output}
   local gradInputTable = recurrentModule:updateGradInput(inputTable, gradOutput)
   gradInput, self.gradPrevOutput = unpack(gradInputTable)
   if self.userPrevOutput then self.userGradPrevOutput = self.gradPrevOutput end
   
   return gradInput
end

function ConvRNN:_accGradParameters(input, gradOutput, scale)
   local stepr = self.accGradParametersStep - 1
   assert(stepr >= 1)
   
   -- set the output/gradOutput states of current Module
   local recurrentModule = self:getStepModule(stepr)
   
   -- backward propagate through this stepr
   local output = (stepr == 1) and (self.userPrevOutput or self.zeroTensor) or self.outputs[stepr-1]
   local inputTable = {input, output}
   local gradOutput = (stepr == self.stepr-1) and gradOutput or self._gradOutputs[stepr]
   recurrentModule:accGradParameters(inputTable, gradOutput, scale)
   return gradInput
end

function ConvRNN:__tostring__()
   return string.format('%s(%d -> %d)', torch.type(self), self.inputSize, self.outputSize)
end

-- migrate GRUs params to BGRUs params
function ConvRNN:migrate(params)
   local _params = self:parameters()
   assert(#params == 6, '# of source params should be 6.')
   assert(#_params == 9, '# of destination params should be 9.')
   _params[1]:copy(params[1]:narrow(1,1,self.outputSize))
   _params[2]:copy(params[2]:narrow(1,1,self.outputSize))
   _params[3]:copy(params[1]:narrow(1,self.outputSize+1,self.outputSize))
   _params[4]:copy(params[2]:narrow(1,self.outputSize+1,self.outputSize))
   _params[5]:copy(params[3]:narrow(1,1,self.outputSize))
   _params[6]:copy(params[3]:narrow(1,self.outputSize+1,self.outputSize))
   _params[7]:copy(params[4])
   _params[8]:copy(params[5])
   _params[9]:copy(params[6])
end
