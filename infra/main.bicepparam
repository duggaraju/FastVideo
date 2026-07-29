using './main.bicep'

param prefix = 'spotvideo'
param systemVmSize = 'Standard_D4s_v5'
param spotVmSize = 'Standard_D8s_v5'
param spotMinCount = 0
param spotMaxCount = 20