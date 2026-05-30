const
  manifest = require('../manifest'),
  webpack  = require('webpack');

const plugins = [];

if (manifest.IS_DEVELOPMENT) {
  plugins.push(new webpack.HotModuleReplacementPlugin());
}

module.exports = plugins;
